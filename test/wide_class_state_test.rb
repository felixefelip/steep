require_relative "test_helper"
require_relative "specializations_project_helper"

class WideClassStateTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RULES = (1..40).map { |index| "    inflect.singular(/(octop#{index}|vir)(us|i)$/i, '\\1us')" }.join("\n")

  RUBY = <<~RUBY
    module Inf
      class Rules
        @__instance__ = {}
        attr_reader :singulars

        def self.instance(locale = :en) = (@__instance__[locale] ||= new)

        def initialize
          @singulars = []
        end

        def singular(rule, replacement)
          @singulars.prepend([rule, replacement])
        end
      end

      def self.inflections(locale = :en)
        if block_given?
          yield Rules.instance(locale)
        else
          Rules.instance(locale)
        end
      end
    end

    module Inf
      inflections(:en) do |inflect|
    #{RULES}
        inflect.singular(/s$/i, "")
      end
    end

    class Post
      def self.singularize(word)
        result = word.dup
        Inf.inflections(:en).singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end

      def self.m(name) = class_eval("def \#{singularize(name.to_s)}_ids; []; end")
      m :posts
    end
  RUBY

  RBS = <<~RBS
    module Inf
      class Rules
        self.@__instance__: Hash[Symbol, Rules]
        attr_reader singulars: Array[untyped]
        def self.instance: (?Symbol locale) -> Rules
        def initialize: () -> void
        def singular: (untyped rule, untyped replacement) -> Array[untyped]
      end
      def self.inflections: (?Symbol locale) ?{ (Rules) -> untyped } -> untyped
    end
    class Post
      def self.singularize: (String word) -> String
      def self.m: (Symbol name) -> untyped
    end
  RBS

  def test_a_macro_reads_a_table_of_rules_a_block_registers_one_at_a_time
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", RUBY)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run

      assert_equal ["def post_ids; []; end"], runner.evals.values.flatten.map { |chunk| chunk&.source }
    end
  end
end
