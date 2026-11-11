require_relative "test_helper"
require_relative "specializations_project_helper"

# A local holding a literal that a loop or a block assigns again is not that
# literal once the loop has run.
class AssignedLiteralsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Specializations = Steep::Specializations

  def records(rbs, ruby, method)
    in_tmpdir do
      write("sig/counter.rbs", rbs)
      write("app/counter.rb", ruby)
      return Specializations::Runner.new(setup_project).run.fetch(method)
    end
  end

  def test_a_while_loop_reassigning_a_literal_parameter_leaves_its_class
    assert_equal({ "(3)" => "::Integer" }, records(<<~RBS, <<~RUBY, "Counter#count"))
      class Counter
        def count: (Integer limit, ?untyped start) -> untyped
      end
      class Caller
        def call: () -> untyped
      end
    RBS
      class Counter
        def count(limit, start = 0)
          value = start
          index = 0
          while index < limit
            value += 1
            index += 1
          end
          value
        end
      end

      class Caller
        def call = Counter.new.count(3)
      end
    RUBY
  end

  def test_a_block_reassigning_a_literal_parameter_leaves_its_class
    assert_equal({ "(::Array[::Integer], 0)" => "::Integer" }, records(<<~RBS, <<~RUBY, "Counter#count"))
      class Counter
        def count: (Array[Integer] items, ?untyped start) -> untyped
      end
      class Caller
        def call: (Array[Integer] items) -> untyped
      end
    RBS
      class Counter
        def count(items, start = 0)
          value = start
          items.each { |item| value += item }
          value
        end
      end

      class Caller
        def call(items) = Counter.new.count(items, 0)
      end
    RUBY
  end
end
