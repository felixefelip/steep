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

  def reach(source)
    Steep::LocalReach.reach(body(source))
  end

  def test_a_frame_handed_out_reaches_every_local
    [
      "binding.local_variable_get(:x)",
      "Kernel.binding.local_variable_set(:x, 2)",
      "self.binding.local_variable_set(:x, 2)",
      "-> {}.binding.local_variable_set(:x, 2)",
      "object&.binding",
      "send(:binding).local_variable_set(:x, 2)",
      "send(name)",
      "method(:eval)",
      "object.method(:instance_eval)",
      "method(name)"
    ].each do |call|
      assert reach("def run = #{call}").every, call
    end
  end

  def test_a_string_run_more_than_once_reaches_every_local
    assert reach("def run(xs) = xs.each { |x| eval(x) }").every
    assert reach("def run = while more?; module_eval(next_source); end").every
    assert reach("def run = ->(s) { eval(s) }").every
    assert reach(<<~RUBY).every
      def run
        begin
          eval(source)
        rescue
          retry
        end
      end
    RUBY
  end

  def test_a_string_run_once_reaches_what_runs_after_it
    reach = reach(<<~RUBY)
      def run(owner)
        before = "x"
        parts = [before]
        result = owner.module_eval(parts.join)
        after = 1
        [after, result]
      end
    RUBY

    refute reach.every
    assert_equal Set[:result, :after], reach.names
  end

  def test_every_string_evaluation_shape
    [
      "eval('x')",
      "Kernel.eval('x = 2')",
      "Object.new.instance_eval('x = 2')",
      "Object.class_eval('x = 2')",
      "Object.module_eval(source)",
      "__send__(:eval, 'x = 2')"
    ].each do |call|
      assert_equal Set[:later], reach("def run = (#{call}; later = 1)").names, call
    end
  end

  def test_the_locals_a_caller_reads_after_the_body
    assert_equal Set[:parts], Steep::LocalReach.reach(body("def run(parts) = eval(source)"), outliving: [:parts]).names
    assert_equal Set[], Steep::LocalReach.reach(body("def run(parts) = parts << 1"), outliving: [:parts]).names
  end

  def test_calls_that_reach_no_local
    [
      "Object.class_eval { def x = 1 }",
      "object.instance_eval(&block)",
      "send(:puts, 'x')",
      "public_send('size')",
      "object.method(:to_s)",
      "method(:binding)"
    ].each do |call|
      assert_equal Steep::LocalReach::NOWHERE, reach("def run = (#{call}; later = 1)"), call
    end
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

  def test_accumulators_read_an_array_a_string_run_before_cannot_reach
    analysis = Steep::Accumulators.analyze(parse(<<~RUBY))
      class Scans
        def run(owner)
          parts = []
          parts << "a"
          owner.module_eval(parts.join(";"))
          nil
        end
      end
    RUBY

    refute_empty analysis.at_reads
  end

  def test_accumulators_decline_an_array_read_after_a_string_runs
    analysis = Steep::Accumulators.analyze(parse(<<~RUBY))
      class Scans
        def run(owner)
          parts = []
          parts << "a"
          owner.module_eval("parts << 'b'")
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

  def test_local_assignments_read_a_name_a_string_run_after_cannot_reach
    analysis = Steep::LocalAssignments.analyze(parse(<<~'RUBY'))
      def run(owner)
        name = "a"
        owner.module_eval("def #{name}; end")
      end
    RUBY

    refute_empty analysis.interpolated
  end
end
