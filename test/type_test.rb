require_relative "test_helper"

class TypeTest < Minitest::Test
  Types = Steep::AST::Types

  # A set is unordered and without repeats, so two written differently are one
  # type — which is what a `Tuple` of the same members is not.
  def test_finite_set_is_normalised
    a = Types::Literal.new(value: "a")
    b = Types::Literal.new(value: "b")

    written_one_way = Types::FiniteSet.new(types: [b, a, b])
    written_another = Types::FiniteSet.new(types: [a, b])

    assert_equal written_another, written_one_way
    assert_equal written_another.hash, written_one_way.hash
    assert_equal %q(Set{"a", "b"}), written_one_way.to_s
    assert_equal %q(("a" | "b")), written_one_way.element_type.to_s
    refute_equal Types::Tuple.new(types: [a, b]), written_another
  end

  def test_level
    assert_equal [0], Types::Var.new(name: :foo).level
    assert_equal [0, 0], Types::Intersection.build(types: [Types::Var.new(name: :foo),
                                                           Types::Var.new(name: :bar)]).level
    assert_equal [1], Types::Any.new.level
    assert_equal [0, 0], Types::Name.new_instance(name: :"String", args: [Types::Var.new(name: :foo)]).level
    assert_equal [0, 1], Types::Name.new_instance(name: :"String", args: [Types::Any.new]).level
    assert_equal [0, 2], Types::Name.new_instance(name: :"String", args: [Types::Any.new, Types::Any.new]).level
    assert_equal [0, 0, 1], Types::Union.build(types: [
      Types::Name.new_instance(name: :"String", args: [Types::Any.new]),
      Types::Var.new(name: :x)
    ]).level
  end
end
