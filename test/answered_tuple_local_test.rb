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
      def wrapped: () -> untyped
      def memo: () -> untyped
      @memo: untyped
    end
    class P
      def wide: (:fr locale) -> untyped
      def wrapped: (:fr locale) -> untyped
      def memo: (:fr locale) -> untyped
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

      def wrapped
        begin
          segs = to_a
          segs.compact!
          segs.length > 1 ? segs : nil
        end
      end

      def memo
        @memo ||=
          begin
            segs = to_a
            segs.compact!
            segs.length > 1 ? segs : nil
          end
      end
    end

    class P
      def wide(locale) = Tag.new(locale).wide
      def wrapped(locale) = Tag.new(locale).wrapped
      def memo(locale) = Tag.new(locale).memo
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

  def test_follows_the_local_inside_a_begin_block
    found = types(TAG)

    assert_equal "nil", found.fetch("wrapped")
    assert_equal "nil", found.fetch("memo")
  end

  def test_declines_inside_a_begin_block_where_a_statement_between_may_reach_the_array
    ruby = TAG.sub("segs.compact!\n      segs.length > 1 ? segs", "segs.compact!\n      grow!\n      segs.length > 1 ? segs")
    refute_equal TAG, ruby
    found = types(ruby)

    refute_equal "nil", found.fetch("wrapped")
  end
end
