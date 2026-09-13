require_relative "test_helper"

class LiteralIntrinsicsTest < Minitest::Test
  MethodDecl = Struct.new(:method_name)
  MethodCall = Struct.new(:method_decls)

  def test_unexpected_fold_failure_is_logged_and_declined
    method = Object.new
    method.define_singleton_method(:source_location) { nil }
    method.define_singleton_method(:bind) do |_receiver|
      -> { raise RuntimeError, "boom" }
    end

    warnings = []
    debug_messages = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |&block| warnings << block.call }
    logger.define_singleton_method(:debug) { |&block| debug_messages << block.call }

    call = MethodCall.new([MethodDecl.new("::String#upcase")])
    receiver_type = Steep::AST::Types::Literal.new(value: "yellow")
    registry = Steep::Project::LiteralMethodRegistry.new
    entry = Steep::LiteralIntrinsics::ENTRIES.fetch("::String#upcase")

    result = entry.stub(:method, method) do
      Steep.stub(:logger, logger) do
        Steep::LiteralIntrinsics.fold(
          call: call,
          receiver_type: receiver_type,
          argument_types: [],
          override_registry: registry
        )
      end
    end

    assert_nil result
    assert_includes warnings.join("\n"), "unexpected failure for ::String#upcase: RuntimeError: boom"
    assert_includes debug_messages.join("\n"), "RuntimeError"
    assert_includes debug_messages.join("\n"), "boom"
  end
end
