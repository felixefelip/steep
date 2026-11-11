require_relative "test_helper"
require_relative "specializations_project_helper"

# A call that writes a block is specialized under what that block returns, so
# a body that answers what it yields answers it for this call
# (felixefelip/rbs_infer#535).
class SpecializationsBlockReturnTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Specializations = Steep::Specializations

  def specialize(project, generations: 3)
    generations.times do
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
    end
  end

  def test_a_call_with_a_block_returns_what_the_body_makes_of_the_block_return
    in_tmpdir do
      write("sig/bag.rbs", <<~RBS)
        class Bag
          def twice: () { (Integer) -> untyped } -> untyped
        end
        class Caller
          def call: () -> untyped
        end
      RBS
      write("app/bag.rb", <<~RUBY)
        class Bag
          def twice = yield(1) + yield(2)
        end

        class Caller
          def call = Bag.new.twice { |n| 3 }
        end
      RUBY
      project = setup_project
      specialize(project)

      assert_equal({ "() &-> ::Integer" => "::Integer" }, Specializations::Runner.new(project).run.fetch("Bag#twice"))
      assert_equal "::Integer", body_types(project, current_dir + "app/bag.rb").fetch("call")
    end
  end

  def test_a_block_returning_a_type_variable_of_its_caller_keys_nothing
    in_tmpdir do
      write("sig/box.rbs", <<~RBS)
        class Box[T]
          def item: () -> T
          def run: () { () -> untyped } -> untyped
          def via: () -> untyped
        end
      RBS
      write("app/box.rb", <<~RUBY)
        class Box
          def item = @item
          def run = yield
          def via = run { item }
        end
      RUBY

      assert_nil Specializations::Runner.new(setup_project).run["Box#run"]
    end
  end

  def test_a_core_method_written_in_ruby_answers_for_the_block_its_call_writes
    in_tmpdir do
      write("sig/shapes.rbs", <<~RBS)
        class Circle
          def area: ((5 | 2) scale) -> (15 | 6)
        end
        class Square
          def area: ((5 | 2) scale) -> (20 | 8)
        end
        class Caller
          def total: () -> untyped
        end
      RBS
      write("app/array.rb", <<~RUBY)
        class Array
          def sum(init = 0)
            value = init
            index = 0
            while index < length
              element = self[index]
              element = yield(element) if block_given?
              value += element
              index += 1
            end
            value
          end
        end
      RUBY
      write("app/shapes.rb", <<~RUBY)
        class Caller
          def total
            shapes = [Circle.new, Square.new]
            shapes.sum { |shape| shape.area(2) }
          end
        end
      RUBY
      project = setup_project
      specialize(project)

      assert_equal "::Integer", body_types(project, current_dir + "app/shapes.rb").fetch("total")
    end
  end
end
