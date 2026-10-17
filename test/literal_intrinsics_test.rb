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

  def fold(key, receiver_type, *argument_types)
    Steep::LiteralIntrinsics.fold(
      call: MethodCall.new([MethodDecl.new(key)]),
      receiver_type: receiver_type,
      argument_types: argument_types,
      override_registry: Steep::Project::LiteralMethodRegistry.new
    )
  end

  def literal(value) = Steep::AST::Types::Literal.new(value: value)

  def union(*values) = Steep::AST::Types::Union.build(types: values.map { |value| literal(value) })

  def test_a_union_receiver_folds_once_per_member
    assert_equal union("posts", "categories"), fold("::Symbol#to_s", union(:posts, :categories))
  end

  def test_a_union_argument_folds_once_per_member
    regexp = Steep::AST::Types::RegexpLiteral.new(value: /ies\z/)

    assert_equal union("post", "category"), fold("::String#sub", union("post", "categories"), regexp, literal("y"))
  end

  def test_a_tuple_holding_a_union_folds_once_per_choice
    tuple = Steep::AST::Types::Tuple.new(types: [union("def a", "def b"), literal("end")])

    assert_equal union("def a;end", "def b;end"), fold("::Array#join", tuple, literal(";"))
  end

  def test_a_member_that_is_not_a_literal_declines_the_whole_call
    receiver = Steep::AST::Types::Union.build(types: [literal(:posts), Steep::AST::Builtin::Symbol.instance_type])

    assert_nil fold("::Symbol#to_s", receiver)
  end
end
