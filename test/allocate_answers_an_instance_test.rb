require_relative "test_helper"
require_relative "specializations_project_helper"

class AllocateAnswersAnInstanceTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class Main
      def self.on_self: () -> untyped
    end
    class Sub < Main
    end
    class Own
      def self.allocate: () -> Symbol
      def self.own_on_self: () -> untyped
    end
    class P
      def named: () -> untyped
      def on_sub: () -> untyped
      def own: () -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class Main
      class << self
        def on_self = allocate
      end
    end

    class Sub < Main
    end

    class Own
      def self.allocate = :own

      class << self
        def own_on_self = allocate
      end
    end

    class P
      def named = Main.allocate
      def on_sub = Sub.allocate
      def own = Own.allocate
    end
  RUBY

  def types
    in_tmpdir do
      write("sig/p.rbs", RBS)
      write("app/p.rb", RUBY)
      project = setup_project
      runner = Steep::Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
      return body_types(project, current_dir + "app/p.rb")
    end
  end

  def test_allocate_answers_an_object_of_the_class_that_receives_it
    found = types

    assert_equal "::Main", found.fetch("named")
    assert_equal "::Main", found.fetch("on_self")
    assert_equal "::Sub", found.fetch("on_sub")
  end

  def test_an_allocate_the_class_defines_answers_what_it_says
    found = types

    assert_equal "::Symbol", found.fetch("own")
    assert_equal "::Symbol", found.fetch("own_on_self")
  end
end
