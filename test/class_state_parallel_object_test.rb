require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassStateParallelObjectTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RUBY = <<~'RUBY'
    class Uncountables < Array
      def initialize
        @regex_array = []
        super
      end

      def add(words)
        words = words.flatten.map(&:downcase)
        concat(words)
        @regex_array += words.map { |word| to_regex(word) }
        self
      end

      def uncountable?(str)
        @regex_array.any? { |regex| regex.match? str }
      end

      private

      def to_regex(string) = /\b#{::Regexp.escape(string)}\Z/i
    end

    class Rules
      attr_reader :singulars, :uncountables

      def initialize
        @singulars, @uncountables = [], Uncountables.new
      end

      def singular(rule, replacement)
        @singulars.prepend([rule, replacement])
      end

      def uncountable(*words)
        @uncountables.add(words)
      end
    end

    class Holder
      def self.instances = @instances ||= {}
      def self.instance(locale = :en) = (instances[locale] ||= Rules.new)
      instance(:en).singular(/s\z/, "")
      instance(:en).uncountable("fish")
    end

    class Post
      def self.rules = Holder.instance(:en)

      def self.singularize(word)
        result = word.dup
        if word.empty? || rules.uncountables.uncountable?(result)
          result
        else
          rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
          result
        end
      end

      def self.m(name) = class_eval("def #{singularize(name.to_s)}_ids; []; end")
      m %{name}
    end
  RUBY

  RBS = <<~RBS
    class Uncountables < Array[String]
      @regex_array: Array[Regexp]
      def initialize: () -> void
      def add: (Array[untyped] words) -> self
      def uncountable?: (String str) -> bool
      private def to_regex: (String string) -> Regexp
    end
    class Rules
      attr_reader singulars: Array[untyped]
      attr_reader uncountables: Uncountables
      def initialize: () -> void
      def singular: (untyped rule, untyped replacement) -> Array[untyped]
      def uncountable: (*String words) -> Uncountables
    end
    class Holder
      self.@instances: Hash[Symbol, Rules]?
      def self.instances: () -> Hash[Symbol, Rules]
      def self.instance: (?Symbol locale) -> Rules
    end
    class Post
      def self.rules: () -> Rules
      def self.singularize: (String word) -> String
      def self.m: (Symbol name) -> untyped
    end
  RBS

  def chunks(name)
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", format(RUBY, name: name))
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.evals.values.flatten.map { |chunk| chunk&.source }
    end
  end

  def test_an_object_an_initialize_starts_in_a_parallel_assignment_answers_its_check
    assert_equal ["def post_ids; []; end"], chunks(":posts")
    assert_equal ["def fish_ids; []; end"], chunks(":fish")
  end
end
