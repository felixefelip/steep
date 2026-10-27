require_relative "test_helper"

class BlockRunTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  RBS = <<~RBS
    class Runner
      def initialize: () -> void
      def maybe: () { () -> void } -> void
    end
    class Counter
      @x: String?
      @n: Integer?
      def joined: (Array[Integer] items) -> Integer
      def summed: (Array[Integer] items) -> Integer
      def maybe: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class Counter
      def joined(items)
        @x = "b"
        items.each { |i| @x = i.to_s }
        @x.size
      end

      def summed(items)
        @n = 0
        items.each { |i| @n = @n + i }
        @n
      end

      def maybe
        @x = "b"
        Runner.new.maybe { @x = "a" }
        @x
      end
    end
  RUBY

  def returns
    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(RUBY)
      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)

        assert_no_error typing
        defs = source.node.children[2].children
        return defs.to_h { |def_node| [def_node.children[0], typing.type_of(node: def_node.children[2].children.last).to_s] }
      end
    end
  end

  def test_an_ivar_a_block_may_run_any_number_of_times_changes_keeps_what_it_held_before_or_after
    types = returns

    assert_equal "::Integer", types[:joined]
    assert_equal "(0 | ::Integer)", types[:summed]
    assert_equal '("b" | ::String)', types[:maybe]
  end

end
