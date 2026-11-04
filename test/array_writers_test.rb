require_relative "test_helper"
require_relative "specializations_project_helper"

# `concat`, `push`, `<<`, … on an array whose element type the checker
# inferred: what they are handed fits up to the class that element stands for.
class ArrayWritersTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class Base end
    class Sub < Base end
    class P
      def pair: () -> [1, 2]
      def concatenated: (Array[Integer] numbers) -> untyped
      def pushed: (Array[Integer] numbers) -> untyped
      def appended: (Integer number) -> untyped
      def narrower_class: () -> untyped
      def other_class: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class P
      def pair = [1, 2]
      def concatenated(numbers) = pair.concat(numbers)
      def pushed(numbers) = pair.push(*numbers)
      def appended(number) = pair << number
      def narrower_class = [Sub.new].concat([Base.new])
      def other_class = [1].concat(["x"])
    end
  RUBY

  def check
    in_tmpdir do
      write("sig/p.rbs", RBS)
      write("app/p.rb", RUBY)
      project = setup_project
      typing = checked(project, current_dir + "app/p.rb")
      return [typing.errors.map { |error| error.node.loc.line }, body_types(project, current_dir + "app/p.rb")]
    end
  end

  def test_a_writer_answers_the_elements_it_adds_to_inferred_ones
    errors, found = check

    assert_equal "::Array[(1 | 2 | ::Integer)]", found.fetch("concatenated")
    assert_equal "::Array[(1 | 2 | ::Integer)]", found.fetch("pushed")
    assert_equal "::Array[(1 | 2 | ::Integer)]", found.fetch("appended")
    assert_equal [6, 7], errors
  end
end
