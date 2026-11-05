require_relative "test_helper"

class StoringClosureByMethodTest < Minitest::Test
  include TestHelper
  include ShellHelper

  def dirs = (@dirs ||= [])

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
  end

  def setup_project
    steepfile = "target :app do\n  signature \"sig\"\n  check \"app\"\nend\n"
    write("Steepfile", steepfile)
    project = Steep::Project.new(steepfile_path: current_dir + "Steepfile")
    Steep::Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
    project
  end

  def chunks(other)
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", RUBY + other)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      return runner.evals.values.map { |found| found.map { |chunk| chunk&.source } }
    end
  end

  RBS = <<~RBS
    class Rules
      @singulars: Array[untyped]
      def initialize: () -> void
      def singular: (untyped rule, untyped replacement) -> Array[untyped]
      def apply: (String word) -> String
    end
    class Inflector
      self.@rule_sets: Hash[Symbol, Rules]
      def self.rule_set_for: (Symbol locale) -> Rules
      def self.singularize: (String word) -> String
    end
    class Post
      def self.has_many_like: (Symbol name) -> untyped
    end
    class Other
      def self.singularize: (String word) -> String
      def self.boot: () -> String
    end
  RBS

  RUBY = <<~'RUBY'
    class Rules
      def initialize
        @singulars = []
      end

      def singular(rule, replacement)
        @singulars.prepend([rule, replacement])
      end

      def apply(word)
        result = word.dup
        @singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end
    end

    class Inflector
      @rule_sets = {}

      def self.rule_set_for(locale) = (@rule_sets[locale] ||= Rules.new)

      def self.singularize(word) = rule_set_for(:en).apply(word)

      rule_set_for(:en).singular(/s\z/, "")
    end

    class Post
      def self.has_many_like(name)
        class_eval "def #{Inflector.singularize(name.to_s)}_ids; []; end"
      end

      has_many_like :posts
    end
  RUBY

  def test_a_method_of_the_same_name_on_another_class_does_not_join_the_closure
    other = <<~'RUBY'
      class Other
        def self.singularize(word) = word
        def self.boot = singularize("x")
      end

      Other.boot
    RUBY

    assert_equal [["def post_ids; []; end"]], chunks(other)
  end

  def test_a_store_reached_from_code_no_method_stands_for_still_declines
    assert_equal [[nil]], chunks("Inflector.rule_set_for(:fr).singular(/x/, \"\")\n")
  end
end
