require_relative "test_helper"

class ConstructorReturnReadsTest < Minitest::Test
  def built(type)
    Steep::Specializations::Store.new(methods: {}, source: nil, receivers: {}, bodies: {}, typed: { "Box.new" => { "()" => type } })
  end

  def test_a_read_of_a_constructor_return_holds_only_while_the_return_does
    reads = Steep::Specializations::Reads.new
    built(Steep::AST::Builtin.nil_type).with_reads(reads).return_type("Box.new", "()", factory: nil)

    assert reads.same?(built(Steep::AST::Builtin.nil_type))
    refute reads.same?(built(Steep::AST::Builtin::Integer.instance_type))
  end
end
