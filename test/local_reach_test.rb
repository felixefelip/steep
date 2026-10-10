require_relative "test_helper"

class LocalReachTest < Minitest::Test
  def parse(source)
    Steep::Source.new_parser.parse(Parser::Source::Buffer.new("a.rb", source: source))
  end

  def body(source)
    parse(source).children[2]
  end

  def test_each_node_stops_at_a_body_of_its_own
    types = [] #: Array[Symbol]
    Steep::LocalReach.each_node(body(<<~RUBY)) { |node| types << node.type }
      def run
        x = 1
        def inner = x
      end
    RUBY

    assert_equal %i[begin lvasgn int], types
  end

  def test_mentions_count_reads_and_writes
    assert_equal 3, Steep::LocalReach.mentions(body(<<~RUBY), :x)
      def run
        x = 1
        x += 1
        foo(x)
        y = 2
      end
    RUBY
  end

  def test_reflective_calls
    assert Steep::LocalReach.reflective?(body("def run = binding.local_variable_get(:x)"))
    assert Steep::LocalReach.reflective?(body("def run = eval('x')"))
    refute Steep::LocalReach.reflective?(body("def run = object.binding"))
  end

  def test_argument_values_include_keyword_values
    call = body("def run(a, b, d, e) = foo(a, *b, c: d, **e)")
    values = Steep::LocalReach.argument_values(call.children.drop(2))

    assert_equal %i[a splat d], values.map { |node| node.type == :lvar ? node.children[0] : node.type }
  end

  def test_accumulators_decline_a_reflective_body
    analysis = Steep::Accumulators.analyze(parse(<<~RUBY))
      class Scans
        def run
          parts = []
          parts << "a"
          binding.local_variable_get(:parts) << "b"
          parts.join(";")
        end
      end
    RUBY

    assert_empty analysis.at_reads
  end

  def test_local_assignments_decline_a_reflective_body
    analysis = Steep::LocalAssignments.analyze(parse(<<~'RUBY'))
      def run
        name = "a"
        binding.local_variable_set(:name, "b")
        "def #{name}"
      end
    RUBY

    assert_empty analysis.interpolated
  end
end
