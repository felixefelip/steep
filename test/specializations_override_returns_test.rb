require_relative "test_helper"
require_relative "specializations_project_helper"

# A call on a receiver typed as a base class returns what any body the
# receiver may run returns: the base's and each subclass override's
# (felixefelip/steep#404).
class SpecializationsOverrideReturnsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Specializations = Steep::Specializations

  SHAPES_RBS = <<~RBS
    class Shape
      def area: (Integer scale) -> Integer
    end
    class Circle < Shape
      def area: (Integer scale) -> Integer
    end
    class Square < Shape
      def area: (Integer scale) -> Integer
    end
    class Canvas
      def draw: (Shape shape) -> untyped
      def draw_circle: (Circle circle) -> untyped
    end
  RBS

  SHAPES_RUBY = <<~RUBY
    class Shape
      def area(scale) = scale
    end

    class Circle < Shape
      def area(scale) = scale * 3
    end

    class Square < Shape
      def area(scale) = scale * 4
    end

    class Canvas
      def draw(shape) = shape.area(5)
      def draw_circle(circle) = circle.area(5)
    end
  RUBY

  def test_runner_specializes_each_override_a_base_typed_call_may_run
    in_tmpdir do
      write("sig/shapes.rbs", SHAPES_RBS)
      write("app/shapes.rb", SHAPES_RUBY)
      project = setup_project
      runner = Specializations::Runner.new(project)
      methods = runner.run

      assert_equal({ "(5)" => "5" }, methods.fetch("Shape#area"))
      assert_equal({ "(5)" => "15" }, methods.fetch("Circle#area"))
      assert_equal({ "(5)" => "20" }, methods.fetch("Square#area"))

      runner.write(methods)
      project.reload_specializations!
      types = body_types(project, current_dir + "app/shapes.rb")

      assert_equal "(5 | 15 | 20)", types.fetch("draw")
      assert_equal "15", types.fetch("draw_circle")
    end
  end

  def test_a_base_instance_handing_itself_on_runs_only_the_base_body
    in_tmpdir do
      write("sig/shapes.rbs", <<~RBS)
        class Shape
          def paint: (Canvas canvas) -> Integer
          def area: (Integer scale) -> Integer
        end
        class Circle < Shape
          def area: (Integer scale) -> Integer
        end
        class Canvas
          def draw: (Shape shape) -> Integer
        end
        class Caller
          def base: () -> untyped
          def circle: () -> untyped
        end
      RBS
      write("app/shapes.rb", <<~RUBY)
        class Shape
          def paint(canvas) = canvas.draw(self)
          def area(scale) = scale
        end

        class Circle < Shape
          def area(scale) = scale * 3
        end

        class Canvas
          def draw(shape) = shape.area(5)
        end

        class Caller
          def base = Shape.new.paint(Canvas.new)
          def circle = Circle.new.paint(Canvas.new)
        end
      RUBY
      project = setup_project
      3.times do
        runner = Specializations::Runner.new(project)
        runner.write(runner.run)
        project.reload_specializations!
      end

      types = body_types(project, current_dir + "app/shapes.rb")

      assert_equal ["5", "15"], types.values_at("base", "circle")
    end
  end

  def test_a_base_typed_call_returns_the_declared_return_of_each_override
    in_tmpdir do
      write("sig/shapes.rbs", <<~RBS)
        class Shape
          def area: (5 scale) -> 5
        end
        class Circle < Shape
          def area: ((5 | 2) scale) -> (15 | 6)
        end
        class Canvas
          def draw: (Shape shape) -> untyped
        end
      RBS
      write("app/shapes.rb", <<~RUBY)
        class Shape
          def area(scale) = scale
        end

        class Circle < Shape
          def area(scale) = scale * 3
        end

        class Canvas
          def draw(shape) = shape.area(5)
        end
      RUBY

      assert_equal "(5 | 15 | 6)", body_types(setup_project, current_dir + "app/shapes.rb").fetch("draw")
    end
  end

  def test_an_override_whose_return_the_base_declares_adds_nothing
    in_tmpdir do
      write("sig/shapes.rbs", <<~RBS)
        class Shape
          def area: (Integer scale) -> Integer
        end
        class Circle < Shape
          def area: (Integer scale) -> 15
        end
        class Canvas
          def draw: (Shape shape) -> untyped
        end
      RBS
      write("app/shapes.rb", <<~RUBY)
        class Shape
          def area(scale) = scale
        end

        class Circle < Shape
          def area(scale) = 15
        end

        class Canvas
          def draw(shape) = shape.area(5)
        end
      RUBY

      assert_equal "::Integer", body_types(setup_project, current_dir + "app/shapes.rb").fetch("draw")
    end
  end

  def test_a_subclass_the_receiver_type_cannot_hold_adds_nothing
    in_tmpdir do
      write("sig/labels.rbs", <<~RBS)
        class Labels < Hash[Symbol, Integer]
          def []: (Symbol key) -> 1
        end
        class Reader
          def read: (Hash[Symbol, String] names) -> untyped
        end
      RBS
      write("app/labels.rb", <<~RUBY)
        class Labels < Hash
          def [](key) = 1
        end

        class Reader
          def read(names) = names[:a]
        end
      RUBY

      assert_equal "::String", body_types(setup_project, current_dir + "app/labels.rb").fetch("read")
    end
  end
end
