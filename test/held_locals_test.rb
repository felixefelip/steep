require_relative "test_helper"

# Which locals of a method body own the object they hold
# (felixefelip/steep#205, stage 2).
class HeldLocalsTest < Minitest::Test
  def parse(source)
    Steep::Source.new_parser.parse(Parser::Source::Buffer.new("a.rb", source: source))
  end

  def held(source)
    def_node = parse(source)
    locals = Steep::TypeInference::HeldLocals.of(def_node)
    names = [] #: Array[Symbol]
    each_node(def_node) { |node| names << node.children[0] if %i[lvasgn arg optarg kwarg].include?(node.type) }
    names.uniq.select { |name| locals.held?(name) }
  end

  def each_node(node, &block)
    return unless node.is_a?(Parser::AST::Node)

    yield node
    node.children.each { |child| each_node(child, &block) }
  end

  def test_receiver_and_argument
    assert_equal [:param, :r], held(<<~RUBY)
      def run(param)
        r = Reflection.new(param)
        r.rename(:articles)
        Writer.define(r, owner: param)
      end
    RUBY
  end

  def test_a_second_name
    refute_includes held(<<~RUBY), :r
      def run
        r = Reflection.new(:posts)
        other = r
        other.name
      end
    RUBY
  end

  def test_returned_stored_or_interpolated
    assert_equal [], held(<<~RUBY)
      def run(a, b, c)
        @r = a
        "\#{b}"
        c
      end
    RUBY
  end

  def test_twice_in_one_call
    assert_equal [:c], held(<<~RUBY)
      def run(a, b, c)
        Writer.pair(a, a.rename(:x))
        b.foo(b.bar)
        Writer.pair(wrap(c))
      end
    RUBY
  end

  def test_inside_a_block_a_loop_or_a_rescue
    assert_equal [:r], held(<<~RUBY)
      def run(a, b, c)
        r = Reflection.new(:posts)
        r.each { a.rename(:x) }
        b.rename(:y) while b.more?
        begin
          r.call
        rescue
          c.rename(:z)
        end
      end
    RUBY
  end

  def test_assigned_twice_or_reassigned_parameter
    assert_equal [:other], held(<<~RUBY)
      def run(param, other = param)
        r = Reflection.new(:a)
        r = Reflection.new(:b)
        param = Reflection.new(:c)
        r.name
      end
    RUBY
  end

  def test_compound_assignment
    assert_equal [], held(<<~RUBY)
      def run
        r = Reflection.new(:a)
        r ||= Reflection.new(:b)
        a, b = Reflection.new(:c), 1
        r.name
      end
    RUBY
  end

  def test_a_bare_super_hands_every_parameter_on
    assert_equal [:r], held(<<~RUBY)
      def run(param)
        super
        r = Reflection.new(:a)
        r.name
      end
    RUBY
  end

  def test_reflection_on_locals
    assert_equal [], held(<<~RUBY)
      def run(param)
        binding.local_variable_get(:param)
      end
    RUBY
  end

  def test_the_value_assigned
    def_node = parse(<<~RUBY)
      def run
        r = Reflection.new(:posts)
        s = Reflection.new(:comments)
        t = s
        r.name
      end
    RUBY
    locals = Steep::TypeInference::HeldLocals.of(def_node)
    first, second = def_node.children[2].children.take(2).map { |assignment| assignment.children[1] }

    assert locals.held_value?(first)
    refute locals.held_value?(second)
  end
end
