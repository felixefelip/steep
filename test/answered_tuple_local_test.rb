require_relative "test_helper"
require_relative "specializations_project_helper"

class AnsweredTupleLocalTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class Tag
      @tag: Symbol
      @subtags: Array[String]
      def initialize: (Symbol tag) -> void
      attr_reader tag: Symbol
      def subtags: () -> Array[String]
      def to_a: () -> Array[String]
      def grow!: () -> Array[String]
      def wide: () -> untyped
    end
    class P
      def wide: (:fr locale) -> untyped
    end
  RBS

  TAG = <<~RUBY
    class Tag
      def initialize(tag)
        @tag = tag
      end

      attr_reader :tag

      def subtags = @subtags = tag.to_s.split('-').map!(&:to_s)
      def to_a = subtags
      def grow! = @subtags.push("x")

      def wide
        segs = to_a
        segs.compact!
        segs.length > 1
      end
    end

    class P
      def wide(locale) = Tag.new(locale).wide
    end
  RUBY

  def types(ruby)
    in_tmpdir do
      write("sig/p.rbs", RBS)
      write("app/p.rb", ruby)
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

  def test_a_local_holding_what_a_method_answered_folds_where_only_calls_on_it_run_before_the_read
    assert_equal "false", types(TAG).fetch("wide")
  end

  def test_declines_where_code_that_may_reach_the_array_runs_before_the_read
    {
      "a statement between" => "segs.compact!\n    grow!\n    segs.length > 1",
      "earlier in the reading statement" => "segs.compact!\n    grow! && segs.length > 1",
      "a call on another local" => "segs.compact!\n    other = self\n    other.grow!\n    segs.length > 1",
      "the birth of another local" => "segs.compact!\n    count = grow!.size\n    segs.length > 1"
    }.each do |label, body|
      found = types(TAG.sub("segs.compact!\n    segs.length > 1", body))
      refute_match(/\A(true|false)\z/, found.fetch("wide"), label)
    end
  end
end
