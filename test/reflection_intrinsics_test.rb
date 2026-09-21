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
      ["::Kernel#method", "::Kernel#singleton_class", "::Method#parameters",
       "::Module#instance_method", "::Module#public_instance_method", "::UnboundMethod#parameters"],
      Steep::ReflectionIntrinsics.watched_keys.to_a.sort
    )
    assert_equal ["::Method#parameters"], Steep::ReflectionIntrinsics.method_keys_for("Method")
    assert_equal(
      [:instance_method, :method, :parameters, :public_instance_method, :singleton_class],
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
    handler = ->(*) { ->(_receiver, _arguments, _factory) { raise RuntimeError, "boom" } }

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
end
