require_relative "test_helper"
require_relative "specializations_project_helper"

class SettledMemoTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class Tag
      @tag: Symbol
      @own: Array[Symbol]
      @branch: Array[Symbol]
      @twin: Array[Symbol]
      def initialize: (Symbol tag) -> void
      attr_reader tag: Symbol
      def own: () -> Array[Symbol]
      def branch: () -> Array[Symbol]
      def twin: () -> Array[Symbol]
      def self.build: (Symbol tag) -> Tag
    end
    class P
      def own: (:fr locale) -> untyped
      def branch: (:fr locale) -> untyped
      def twin: (:fr locale) -> untyped
    end
  RBS

  TAG = <<~RUBY
    class Tag
      def initialize(tag)
        @tag = tag
      end

      attr_reader :tag

      def own = @own ||= [tag]
      def branch = @branch ||= tag == :fr ? [] : [tag]

      def twin
        @twin ||= begin
          copy = self.class.build(tag)
          [copy.tag]
        end
      end

      def self.build(tag) = new(tag)
    end
  RUBY

  USE = <<~RUBY
    class P
      def own(locale) = Tag.new(locale).own
      def branch(locale) = Tag.new(locale).branch
      def twin(locale) = Tag.new(locale).twin
    end
  RUBY

  def types(ruby, rbs: RBS)
    in_tmpdir do
      write("sig/p.rbs", rbs)
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

  def test_a_memo_only_it_writes_answers_its_value_on_an_object_the_checker_follows
    found = types(TAG + USE)

    assert_equal "[:fr]", found.fetch("own")
    assert_equal "[]", found.fetch("branch")
    assert_equal "[:fr]", found.fetch("twin")
  end

  def test_declines_a_memo_something_else_writes_or_whose_value_may_change
    {
      "another writer" => ["def own = @own ||= [tag]", "def own = @own ||= [tag]\n  def reset = @own = [:x]", "def reset: () -> Array[Symbol]\n  def own:"],
      "a value another method changes" => ["def own = @own ||= [tag]", "def own = @own ||= [tag]\n  def rename(tag) = @tag = tag", "def rename: (Symbol tag) -> Symbol\n  def own:"]
    }.each do |label, (from, to, sig)|
      found = types(TAG.sub(from, to) + USE, rbs: RBS.sub("def own:", sig))
      refute_equal "[:fr]", found.fetch("own"), label
    end
  end

  def test_declines_a_memo_whose_value_calls_a_class_method_a_subclass_redefines
    ruby = TAG + "class Copy < Tag\n  def self.build(tag) = Tag.new(tag)\nend\n" + USE
    rbs = RBS + "class Copy < Tag\nend\n"
    refute_equal "[:fr]", types(ruby, rbs: rbs).fetch("twin")
  end
end
