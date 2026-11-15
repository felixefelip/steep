require_relative "test_helper"

# Which ivars of `self` a method body reaches only through calls made on them
# (felixefelip/steep#312).
class HeldIvarsTest < Minitest::Test
  def parse(source)
    Steep::Source.new_parser.parse(Parser::Source::Buffer.new("a.rb", source: source))
  end

  def test_receiver_through_the_ivar_or_its_reader
    ivars = held_ivars(<<~RUBY)
      def run
        @foo = Foo.new({})
        foo.my_hash[:bar] = 10
        self.foo.my_hash
        @foo.my_hash[:bar]
      end
    RUBY

    assert ivars.held?(:@foo)
  end

  def test_the_value_assigned_is_held
    def_node = parse(<<~RUBY)
      def run
        @foo = Foo.new({})
        foo.my_hash
      end
    RUBY

    assert reader(def_node).held_value?(new_call(def_node))
  end

  def test_a_second_name_an_argument_or_a_return
    ["x = foo\n  x.my_hash", "Writer.write(@foo)", "foo.merge(foo)", "foo.my_hash\n  @foo"].each do |body|
      refute held_ivars("def run\n  @foo = Foo.new({})\n  #{body}\nend\n").held?(:@foo), body
    end
  end

  def test_a_mention_that_may_run_later_or_again
    ["[1].each { foo.my_hash }", "-> { @foo.my_hash }", "while ready?\n    foo.my_hash\n  end"].each do |body|
      refute held_ivars("def run\n  @foo = Foo.new({})\n  #{body}\n  nil\nend\n").held?(:@foo), body
    end
  end

  def test_an_assignment_whose_value_something_takes
    ["x = (@foo = Foo.new({}))\n  foo.my_hash", "@foo ||= Foo.new({})\n  foo.my_hash", "foo.my_hash\n  @foo = Foo.new({})"].each do |body|
      def_node = parse("def run\n  #{body}\nend\n")

      refute reader(def_node).held_value?(new_call(def_node)), body
    end
  end

  def test_the_value_a_parallel_assignment_hands_the_ivar_is_held
    def_node = parse("def run\n  @bar, @foo = [], Foo.new({})\n  foo.my_hash\nend\n")
    ivars = reader(def_node)

    assert ivars.held?(:@foo)
    assert ivars.held_value?(new_call(def_node))
  end

  def test_declines_a_parallel_assignment_that_splats_or_whose_value_something_takes
    ["@bar, @foo = *bars, Foo.new({})", "@bar, @foo = Foo.new({})", "@bar, *@foo = [], Foo.new({})", "x = (@bar, @foo = [], Foo.new({}))"].each do |assignment|
      def_node = parse("def run\n  #{assignment}\n  foo.my_hash\nend\n")

      refute reader(def_node).held_value?(new_call(def_node)), assignment
    end
    def_node = parse("def run\n  foo.my_hash\n  @bar, @foo = [], Foo.new({})\nend\n")
    refute reader(def_node).held_value?(new_call(def_node)), "last statement"
  end

  def test_an_assignment_in_a_branch_of_a_statement_is_held
    def_node = parse("def run\n  if ready?\n    @foo = Foo.new({})\n  else\n    @foo = {}\n  end\n  foo.my_hash\nend\n")

    assert reader(def_node).held_value?(new_call(def_node))
  end

  def test_a_value_an_if_stores_is_held_through_its_branches
    def_node = parse("def run\n  @foo = if ready? then Foo.new({}) else {} end\n  foo.my_hash\nend\n")

    assert reader(def_node).held_value?(new_call(def_node))
  end

  def test_an_assignment_in_a_condition_is_not_held
    def_node = parse("def run\n  if (@foo = Foo.new({}))\n    foo.my_hash\n  end\n  nil\nend\n")

    refute reader(def_node).held_value?(new_call(def_node))
  end

  def test_the_last_statement_is_held_where_no_call_takes_the_answer
    def_node = parse("def run\n  foo.my_hash\n  @foo = Foo.new({})\nend\n")

    assert reader(def_node, taken: false).held_value?(new_call(def_node))
    refute reader(def_node, taken: true).held_value?(new_call(def_node))
  end

  private

  def reader(def_node, taken: true)
    Steep::TypeInference::HeldIvars.new(def_node, ->(name) { :@foo if name == :foo }, ->(_name) { taken })
  end

  def held_ivars(source)
    reader(parse(source))
  end

  def new_call(node)
    return unless node.is_a?(Parser::AST::Node)
    return node if node.type == :send && node.children[1] == :new

    node.children.each { |child| found = new_call(child) and return found }
    nil
  end
end
