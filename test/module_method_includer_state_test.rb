require_relative "test_helper"
require_relative "specializations_project_helper"

class ModuleMethodIncluderStateTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    interface _Segments
      def to_a: () -> Array[String]
    end
    module Parents : _Segments
      def segments: () -> Array[String]
      def nested?: () -> bool
    end
    class Simple
      include Parents
      @tag: Symbol
      def initialize: (Symbol tag) -> void
      attr_reader tag: Symbol
      def to_a: () -> Array[String]
    end
    class Pair
      include Parents
      @tag: Symbol
      def initialize: (Symbol tag) -> void
      attr_reader tag: Symbol
      def to_a: () -> Array[String]
    end
    class P
      def simple_segments: (:fr locale) -> untyped
      def simple_nested: (:fr locale) -> untyped
      def pair_segments: (:fr locale) -> untyped
      def pair_nested: (:fr locale) -> untyped
    end
  RBS

  RUBY = <<~RUBY
    module Parents
      def segments = to_a

      def nested?
        segs = to_a
        segs.length > 1
      end
    end

    class Simple
      include Parents

      def initialize(tag)
        @tag = tag
      end

      attr_reader :tag

      def to_a = [tag.to_s]
    end

    class Pair
      include Parents

      def initialize(tag)
        @tag = tag
      end

      attr_reader :tag

      def to_a = [tag.to_s, "x"]
    end

    class P
      def simple_segments(locale) = Simple.new(locale).segments
      def simple_nested(locale) = Simple.new(locale).nested?
      def pair_segments(locale) = Pair.new(locale).segments
      def pair_nested(locale) = Pair.new(locale).nested?
    end
  RUBY

  def types
    in_tmpdir do
      write("sig/p.rbs", RBS)
      write("app/p.rb", RUBY)
      project = setup_project
      postconditions = Steep::Postconditions::Runner.new(project)
      postconditions.write(postconditions.run)
      project = setup_project
      runner = Steep::Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
      return body_types(project, current_dir + "app/p.rb")
    end
  end

  def test_a_module_method_runs_the_includers_methods_on_its_state
    found = types

    assert_equal "[\"fr\"]", found.fetch("simple_segments")
    assert_equal "false", found.fetch("simple_nested")
  end

  def test_each_includer_answers_its_own_methods
    found = types

    assert_equal "[\"fr\", \"x\"]", found.fetch("pair_segments")
    assert_equal "true", found.fetch("pair_nested")
  end
end
