require_relative "test_helper"
require_relative "specializations_project_helper"

class SpecializationsTypeParameterAnswerTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def caller_types(body)
    in_tmpdir do
      write("sig/cell.rbs", <<~RBS)
        class Cell[V]
          @value: V
          def initialize: (V value) -> void
          def read: (Symbol key) -> V?
        end
        class Shelf < Cell[Integer]
        end
        class Caller
          def cell: () -> Cell[Integer]
          def shelf: () -> Shelf
          def read_cell: () -> untyped
          def read_shelf: () -> untyped
        end
      RBS
      write("app/cell.rb", <<~RUBY)
        class Cell
          def initialize(value)
            @value = value
          end

          def read(key) = key == :none ? nil : @value
        end

        class Caller
          #{body}
        end
      RUBY
      project = setup_project
      2.times do
        runner = Steep::Specializations::Runner.new(project)
        runner.write(runner.run)
        project.reload_specializations!
      end
      body_types(project, current_dir + "app/cell.rb")
    end
  end

  def test_an_answer_in_the_class_type_parameter_is_read_as_the_receiver_instantiates_it
    assert_equal "::Integer", caller_types("def read_cell = cell.read(:some)").fetch("read_cell")
  end

  def test_an_answer_reached_through_a_subclass_is_read_as_the_subclass_instantiates_its_parent
    assert_equal "::Integer", caller_types("def read_shelf = shelf.read(:some)").fetch("read_shelf")
  end
end
