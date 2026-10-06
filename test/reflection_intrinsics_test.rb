require_relative "test_helper"

class ReflectionIntrinsicsTest < Minitest::Test
  include TestHelper
  include FactoryHelper

  MethodDecl = Struct.new(:method_name)
  MethodCall = Struct.new(:method_decls)

  Registry = Steep::Project::LiteralMethodRegistry

  SIGNATURES = {
    "probe.rbs" => <<~RBS
      module ProbeExt
        def helper: () -> void
      end
      class ProbeBase
        extend ProbeExt
        def self.human_name: (String index) -> String
      end
      class ProbeSub < ProbeBase
      end
    RBS
  }

  def with_probe_factory(&block)
    with_factory(SIGNATURES, nostdlib: false, &block)
  end

  def fold(key, receiver_type, registry, factory, argument_types: [])
    Steep::ReflectionIntrinsics.fold(
      call: MethodCall.new([MethodDecl.new(key)]),
      receiver_type: receiver_type,
      argument_types: argument_types,
      factory: factory,
      override_registry: registry
    )
  end

  def registry_for(source)
    Registry.new.tap { |registry| registry.ingest_source(source, path_name: "test.rb") }
  end

  def singleton(name)
    Steep::AST::Types::Name::Singleton.new(name: RBS::TypeName.parse(name))
  end

  def test_a_singleton_class_names_the_module_it_is_of
    with_probe_factory do |factory|
      type = fold("::Kernel#singleton_class", singleton("::ProbeBase"), Registry.new, factory)

      assert_equal Steep::AST::Types::MetaClass.new(name: RBS::TypeName.parse("::ProbeBase")), type
    end
  end

  # The class that shadows a reflection is the RECEIVER's, so the chain walked
  # is the receiver's own. `Foo.method(:x)` reaches `def self.method` before it
  # reaches Kernel's, and a signature never mentions it.
  def test_a_redefinition_on_the_receiver_declines_the_fold
    registry = registry_for(<<~RUBY)
      class ProbeBase
        def self.singleton_class = self
      end
    RUBY

    assert registry.blocked?("::ProbeBase.singleton_class")
    with_probe_factory do |factory|
      assert_nil fold("::Kernel#singleton_class", singleton("::ProbeBase"), registry, factory)
    end
  end

  # An ancestor of the receiver is on the same chain — including a module the
  # receiver EXTENDS, which is where a singleton method is written as an
  # instance one.
  def test_a_redefinition_on_an_ancestor_declines_the_fold
    inherited = registry_for(<<~RUBY)
      class ProbeBase
        def self.singleton_class = self
      end
    RUBY
    extended = registry_for(<<~RUBY)
      module ProbeExt
        def singleton_class = self
      end
    RUBY

    with_probe_factory do |factory|
      assert_nil fold("::Kernel#singleton_class", singleton("::ProbeSub"), inherited, factory)
      assert_nil fold("::Kernel#singleton_class", singleton("::ProbeSub"), extended, factory)
    end
  end

  # A core class on the chain, which is what `class Object; def singleton_class`
  # is: Ruby runs it, and dispatch still resolves to Kernel's.
  def test_a_redefinition_on_a_core_ancestor_declines_the_fold
    registry = registry_for(<<~RUBY)
      class Object
        def singleton_class = self
      end
    RUBY

    with_probe_factory do |factory|
      assert_nil fold("::Kernel#singleton_class", singleton("::ProbeBase"), registry, factory)
    end
  end

  # Past the class the entry is declared on, nothing can shadow it — the lookup
  # has already found it.
  def test_a_redefinition_below_the_declaring_class_folds
    registry = registry_for(<<~RUBY)
      class BasicObject
        def singleton_class = self
      end
    RUBY

    with_probe_factory do |factory|
      refute_nil fold("::Kernel#singleton_class", singleton("::ProbeBase"), registry, factory)
    end
  end

  # And a class that is not on the chain is not a shadow at all: the check is
  # receiver-aware rather than a name-wide kill switch, which matters for
  # `parameters` — an app writing `def parameters` is ordinary.
  def test_a_redefinition_off_the_chain_folds
    registry = registry_for(<<~RUBY)
      class Unrelated
        def self.singleton_class = self
      end
    RUBY

    assert registry.blocked?("::Unrelated.singleton_class")
    with_probe_factory do |factory|
      refute_nil fold("::Kernel#singleton_class", singleton("::ProbeBase"), registry, factory)
    end
  end

  def test_a_reopen_of_the_declaring_class_declines_the_fold
    registry = registry_for(<<~RUBY)
      module Module
        def instance_method(name) = name
      end
    RUBY

    assert registry.blocked?("::Module#instance_method")
    with_probe_factory do |factory|
      assert_nil fold(
        "::Module#instance_method",
        singleton("::ProbeBase"),
        registry,
        factory,
        argument_types: [Steep::AST::Types::Literal.new(value: :human_name)]
      )
    end
  end

  # An ordinary monkeypatch is not one of these, and paying for the watch has to
  # stop somewhere: only a name one of the tables is keyed by is recorded.
  def test_an_unrelated_reopen_blocks_nothing
    registry = registry_for(<<~RUBY)
      class Object
        def blank? = false
      end
    RUBY

    refute registry.blocked?("::Object#singleton_class")
    refute registry.blocked?("::Kernel#singleton_class")
  end

  def test_watched_keys_and_dispatched_names
    assert_equal(
      ["::Kernel#method", "::Kernel#respond_to?", "::Kernel#singleton_class", "::Method#parameters",
       "::Module#instance_method", "::Module#name", "::Module#public_instance_method", "::UnboundMethod#parameters"],
      Steep::ReflectionIntrinsics.watched_keys.to_a.sort
    )
    assert_equal ["::Method#parameters"], Steep::ReflectionIntrinsics.method_keys_for("Method")
    assert_equal(
      [:instance_method, :method, :name, :parameters, :public_instance_method, :respond_to?, :respond_to_missing?,
       :singleton_class],
      Steep::ReflectionIntrinsics.dispatched_names.to_a.sort
    )
  end

  def test_unexpected_fold_failure_is_logged_and_declined
    warnings = []
    debug_messages = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |&block| warnings << block.call }
    logger.define_singleton_method(:debug) { |&block| debug_messages << block.call }

    entry = Steep::ReflectionIntrinsics::ENTRIES.fetch("::Kernel#singleton_class")
    # `stub` CALLS a callable value, so what it is given is a lambda returning
    # the handler rather than the handler itself.
    handler = ->(*) { ->(_receiver, _arguments, _factory, _registry) { raise RuntimeError, "boom" } }

    with_probe_factory do |factory|
      result = entry.stub(:handler, handler) do
        Steep.stub(:logger, logger) do
          fold("::Kernel#singleton_class", singleton("::ProbeBase"), Registry.new, factory)
        end
      end

      assert_nil result
    end

    assert_includes warnings.join("\n"), "unexpected failure for ::Kernel#singleton_class: RuntimeError: boom"
    assert_includes debug_messages.join("\n"), "boom"
  end

  RESPONDING = {
    "responding.rbs" => <<~RBS
      class Shape
        def area: () -> Integer
        private def secret: () -> void
      end
      class Square < Shape
        def side: () -> Integer
      end
      class Ghost
        private def respond_to_missing?: (Symbol | String, bool) -> bool
      end
      class Card
        def self.build: () -> Card
      end
    RBS
  }

  def responds(receiver_type, name, registry: Registry.new)
    with_factory(RESPONDING, nostdlib: false) do |factory|
      fold("::Kernel#respond_to?", receiver_type, registry, factory,
           argument_types: [Steep::AST::Types::Literal.new(value: name)])
    end
  end

  def instance(name)
    Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse(name), args: [])
  end

  def literal(value)
    Steep::AST::Types::Literal.new(value: value)
  end

  # `ActiveSupport::Delegation`'s `allow_nil: true`: NilClass has no such
  # method, so the condition it writes is decided.
  def test_nil_does_not_respond_to_a_method_nothing_gives_it
    assert_equal literal(false), responds(Steep::AST::Builtin.nil_type, :area)
    assert_equal literal(true), responds(Steep::AST::Builtin.nil_type, :to_a)
  end

  # A `Shape` may be a `Square`, so a method only the subclass has is not one
  # this can answer for; one the class has is every subclass's too.
  def test_an_instance_answers_for_every_subclass_it_may_be
    assert_equal literal(true), responds(instance("::Shape"), :area)
    assert_nil responds(instance("::Shape"), :side)
    assert_equal literal(true), responds(instance("::Square"), :side)
    assert_equal literal(false), responds(instance("::Square"), :radius)
  end

  # `respond_to?` reports public methods; a private one is not.
  def test_a_private_method_is_not_responded_to
    assert_equal literal(false), responds(instance("::Shape"), :secret)
  end

  def test_a_class_object_answers_for_its_class_methods
    assert_equal literal(true), responds(singleton("::Card"), :build)
    assert_equal literal(false), responds(singleton("::Card"), :area)
  end

  def test_a_union_answers_where_every_member_agrees
    union = Steep::AST::Types::Union.build(types: [instance("::Square"), Steep::AST::Builtin.nil_type])

    assert_equal literal(false), responds(union, :radius)
    assert_nil responds(union, :side)
  end

  # Ruby asks `respond_to_missing?` for a method it does not find, so a class
  # whose `respond_to_missing?` is not Kernel's has no "no" this can give —
  # declared in the signatures or written in the project.
  def test_a_respond_to_missing_other_than_the_core_one_declines_a_false_answer
    assert_nil responds(instance("::Ghost"), :anything)

    registry = registry_for(<<~RUBY)
      class Card
        def respond_to_missing?(name, include_private = false) = true
      end
    RUBY
    assert_nil responds(instance("::Card"), :anything, registry: registry)
    assert_equal literal(false), responds(instance("::Square"), :anything, registry: registry)
  end

  def test_a_respond_to_the_project_writes_declines_the_fold
    registry = registry_for(<<~RUBY)
      class Shape
        def respond_to?(name, include_all = false) = false
      end
    RUBY

    assert_nil responds(instance("::Square"), :area, registry: registry)
    assert_equal literal(true), responds(instance("::Card"), :to_s, registry: registry)
  end

  # A module is no class a value is an instance of: whatever includes it may
  # be, and nothing lists those.
  def test_a_module_instance_declines
    assert_nil responds(instance("::Kernel"), :anything)
  end

  def test_include_all_declines
    with_factory(RESPONDING, nostdlib: false) do |factory|
      assert_nil fold("::Kernel#respond_to?", instance("::Shape"), Registry.new, factory,
                      argument_types: [literal(:secret), literal(true)])
    end
  end
end
