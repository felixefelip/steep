require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassStateAnswerTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RUBY = <<~'RUBY'
    class Rules
      attr_reader :singulars

      def initialize
        @singulars = []
      end

      def singular(rule, replacement)
        @singulars.prepend([rule, replacement])
      end
    end

    class Holder
      def self.instances = @instances ||= {}
      def self.instance(locale = :en) = (instances[locale] ||= Rules.new)
      instance(:en).singular(/s\z/, "")
    end
    %{writer}
    class Post
      def self.rules = Holder.instance(:en)

      def self.singularize(word)
        result = word.dup
        %{read}.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end

      def self.m(name) = class_eval("def #{singularize(name.to_s)}_ids; []; end")
      m :posts
    end
  RUBY

  RBS = <<~RBS
    class Rules
      attr_reader singulars: Array[untyped]
      def initialize: () -> Array[untyped]
      def singular: (untyped rule, untyped replacement) -> Array[untyped]
    end
    class Holder
      self.@instances: Hash[Symbol, Rules]?
      def self.instances: () -> Hash[Symbol, Rules]
      def self.instance: (?Symbol locale) -> Rules
    end
    class Other
      def self.add: () -> untyped
    end
    class Post
      def self.rules: () -> Rules
      def self.singularize: (String word) -> String
      def self.m: (Symbol name) -> untyped
    end
  RBS

  WRITER = "class Other\n  def self.add = Holder.instance(:en).singular(/s\\z/, \"z\")\nend\nOther.add\n"

  def chunks(read:, writer: "", ruby: RUBY)
    in_tmpdir do
      write("sig/app.rbs", RBS.sub("    def initialize: () -> Array[untyped]\n", "    @plurals: Array[untyped]\n    def initialize: () -> Array[untyped]\n"))
      write("app/app.rb", format(ruby, read: read, writer: writer))
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.evals.values.flatten.map { |chunk| chunk&.source }
    end
  end

  def test_a_method_outside_the_class_reads_the_element_its_memo_holds
    assert_equal ["def post_ids; []; end"], chunks(read: "Holder.instance(:en)")
  end

  def test_a_method_reads_the_element_through_another_method_that_answers_it
    assert_equal ["def post_ids; []; end"], chunks(read: "rules")
  end

  def test_an_object_whose_initialize_starts_its_arrays_in_a_parallel_assignment_is_followed
    assert_equal ["def post_ids; []; end"], chunks(read: "rules", ruby: RUBY.sub("@singulars = []", "@singulars, @plurals = [], []"))
  end

  def test_declines_an_element_another_class_may_write
    assert_equal [nil], chunks(read: "Holder.instance(:en)", writer: WRITER)
  end
end
