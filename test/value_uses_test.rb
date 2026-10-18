require_relative "test_helper"

# What a method body does with the value of each call in it
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

  def test_steps_statements_and_the_returned_value
    def_node = parse(<<~RUBY)
      def run
        foo.my_hash[:bar][:num2] = 30
        y = foo.my_hash[:bar]
        Kernel.p(@my_hash)
        foo.my_hash[:bar].merge!(num1: 1)
        foo.my_hash[:bar] = { num1: 5 }
      end
    RUBY
    uses = Steep::TypeInference::ValueUses.new(def_node)

    assert uses.step?(find(def_node, "foo.my_hash[:bar]"))
    assert uses.step?(find(def_node, "foo.my_hash"))
    refute uses.step?(find(def_node, "@my_hash"))
    refute uses.step?(find(def_node, "foo.my_hash[:bar].merge!(num1: 1)").children[0])
    refute uses.kept?(find(def_node, "foo.my_hash[:bar][:num2] = 30"))
    refute uses.kept?(find(def_node, "foo.my_hash[:bar] = { num1: 5 }"))
    assert uses.kept?(find(def_node, "y = foo.my_hash[:bar]").children[1])
  end

  def test_a_value_a_block_answers_is_kept
    def_node = parse(<<~RUBY)
      def run
        [1].map { foo.my_hash[:bar] = { num1: 5 } }
        nil
      end
    RUBY

    assert Steep::TypeInference::ValueUses.new(def_node).kept?(find(def_node, "foo.my_hash[:bar] = { num1: 5 }"))
  end
end
