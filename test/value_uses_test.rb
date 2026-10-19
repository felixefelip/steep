require_relative "test_helper"

# Where a method body puts the value of each expression in it
# (felixefelip/steep#314).
class ValueUsesTest < Minitest::Test
  def parse(source)
    Steep::Source.new_parser.parse(Parser::Source::Buffer.new("a.rb", source: source))
  end

  def find(node, source)
    return unless node.is_a?(Parser::AST::Node)
    return node if node.loc.expression&.source == source

    node.children.each { |child| found = find(child, source) and return found }
    nil
  end

  def test_receivers_statements_and_what_is_taken
    def_node = parse(<<~RUBY)
      def run
        foo.my_hash[:bar][:num2] = 30
        y = foo.my_hash[:bar]
        Kernel.p(@my_hash)
        foo.my_hash[:bar] = { num1: 5 }
      end
    RUBY
    uses = Steep::TypeInference::ValueUses.new(def_node)

    assert uses.receiver?(find(def_node, "foo.my_hash[:bar]"))
    assert uses.receiver?(find(def_node, "foo.my_hash"))
    assert uses.left?(find(def_node, "foo.my_hash[:bar][:num2] = 30"))
    assert uses.left?(find(def_node, "foo.my_hash[:bar] = { num1: 5 }"))
    assert uses.taken?(find(def_node, "y = foo.my_hash[:bar]").children[1])
    assert uses.taken?(find(def_node, "@my_hash"))
  end

  def test_every_arm_the_method_finishes_on_is_returned
    def_node = parse(<<~RUBY)
      def run(ready)
        return foo.my_hash[:bar] = { num1: 1 } if ready

        if ready
          foo.my_hash[:bar] = { num1: 2 }
        else
          foo.my_hash[:bar] = { num1: 3 }
        end
      end
    RUBY
    uses = Steep::TypeInference::ValueUses.new(def_node)

    (1..3).each { |num| assert uses.left?(find(def_node, "foo.my_hash[:bar] = { num1: #{num} }")), num }
  end

  def test_a_value_a_block_answers_is_taken
    def_node = parse(<<~RUBY)
      def run
        [1].map { foo.my_hash[:bar] = { num1: 5 } }
        nil
      end
    RUBY

    assert Steep::TypeInference::ValueUses.new(def_node).taken?(find(def_node, "foo.my_hash[:bar] = { num1: 5 }"))
  end
end
