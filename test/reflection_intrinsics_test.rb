require_relative "test_helper"

class ReflectionIntrinsicsTest < Minitest::Test
  MethodDecl = Struct.new(:method_name)
  MethodCall = Struct.new(:method_decls)

  Registry = Steep::Project::LiteralMethodRegistry

  def fold(key, receiver_type, registry, argument_types: [])
    Steep::ReflectionIntrinsics.fold(
      call: MethodCall.new([MethodDecl.new(key)]),
      receiver_type: receiver_type,
      argument_types: argument_types,
      factory: nil,
      override_registry: registry
    )
  end

  def registry_for(source)
    Registry.new.tap { |registry| registry.ingest_source(source, path_name: "test.rb") }
  end

  def test_a_singleton_class_names_the_module_it_is_of
    type = fold("::Kernel#singleton_class", Steep::AST::Builtin::String.module_type, Registry.new)

    assert_equal Steep::AST::Types::MetaClass.new(name: RBS::TypeName.parse("::String")), type
  end

  # A reopen of any class BETWEEN `Kernel` and the receiver answers the call
  # instead, and dispatch still resolves to Kernel's — so the entry names them
  # and one of them being redefined declines the fold.
  def test_a_reopen_of_a_shadowing_class_declines_the_fold
    registry = registry_for(<<~RUBY)
      class Object
        def singleton_class = self
      end
    RUBY

    assert registry.blocked?("::Object#singleton_class")
    assert_nil fold("::Kernel#singleton_class", Steep::AST::Builtin::String.module_type, registry)
  end

  def test_a_reopen_of_the_declaring_class_declines_the_fold
    registry = registry_for(<<~RUBY)
      module Module
        def instance_method(name) = name
      end
    RUBY

    assert registry.blocked?("::Module#instance_method")
    assert_nil fold(
      "::Module#instance_method",
      Steep::AST::Builtin::String.module_type,
      registry,
      argument_types: [Steep::AST::Types::Literal.new(value: :upcase)]
    )
  end

  # An ordinary monkeypatch is not one of these, and paying for the watch has to
  # stop somewhere: only a name the table is keyed by blocks anything.
  def test_an_unrelated_reopen_blocks_nothing
    registry = registry_for(<<~RUBY)
      class Object
        def blank? = false
      end
    RUBY

    refute registry.blocked?("::Object#singleton_class")
    refute registry.blocked?("::Kernel#singleton_class")
  end

  def test_watched_keys_cover_the_shadows
    keys = Steep::ReflectionIntrinsics.watched_keys

    assert_includes keys, "::Kernel#singleton_class"
    assert_includes keys, "::Class#singleton_class"
    assert_includes keys, "::Class#instance_method"
    assert_equal ["::Method#parameters"], Steep::ReflectionIntrinsics.method_keys_for("Method")
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

    result = entry.stub(:handler, handler) do
      Steep.stub(:logger, logger) do
        fold("::Kernel#singleton_class", Steep::AST::Builtin::String.module_type, Registry.new)
      end
    end

    assert_nil result
    assert_includes warnings.join("\n"), "unexpected failure for ::Kernel#singleton_class: RuntimeError: boom"
    assert_includes debug_messages.join("\n"), "boom"
  end
end
