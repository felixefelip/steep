require_relative "test_helper"
require_relative "specializations_project_helper"

class NestedClassStateTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RULES = <<~RUBY
    class Rules
      attr_reader :singulars

      def initialize
        @singulars = []
      end

      def singular(rule, replacement)
        @singulars.prepend([rule, replacement])
      end
    end
  RUBY

  RULES_RBS = <<~RBS
    class Rules
      attr_reader singulars: Array[untyped]
      def initialize: () -> Array[untyped]
      def singular: (untyped rule, untyped replacement) -> Array[untyped]
    end
  RBS

  HOLDER = <<~RUBY
    class Holder
      def self.instances = @instances ||= {}
      def self.instance(locale = :en) = (instances[locale] ||= Rules.new)

      def self.singularize(word)
        result = word.dup
        instance(:en).singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end
    end
  RUBY

  HOLDER_RBS = <<~RBS
    class Holder
      self.@instances: Hash[Symbol, Rules]?
      def self.instances: () -> Hash[Symbol, Rules]
      def self.instance: (?Symbol locale) -> Rules
      def self.singularize: (String word) -> String
    end
  RBS

  def project(defined_on:, nested:)
    prefix = defined_on == :instances ? "def " : "def self."
    extension = defined_on == :instances ? "extend self\n" : ""
    signature_extension = defined_on == :instances ? "extend Inf\n" : ""
    inflections = "#{prefix}inflections(locale = :en)\n  yield Holder.instance(locale) if block_given?\nend\n"
    inflections_rbs = "#{prefix}inflections: (?Symbol locale) ?{ (Rules) -> void } -> untyped\n"
    holder = nested ? "Inf::Holder" : "Holder"
    inner, inner_rbs = nested ? [HOLDER, HOLDER_RBS] : ["", ""]
    outer, outer_rbs = nested ? ["", ""] : [HOLDER, HOLDER_RBS]

    ruby = <<~RUBY
      #{RULES}
      #{outer}
      module Inf
        #{extension}
        #{inner}
        #{inflections}
      end

      module Boot
        Inf.inflections(:en) { |rules| rules.singular(/s\\z/, "") }
      end

      class Post
        def self.m(name) = class_eval("def \#{#{holder}.singularize(name.to_s)}_ids; []; end")
        m :posts
      end
    RUBY
    rbs = <<~RBS
      #{RULES_RBS}
      #{outer_rbs}
      module Inf
        #{signature_extension}
        #{inner_rbs}
        #{inflections_rbs}
      end
      module Boot
      end
      class Post
        def self.m: (Symbol name) -> untyped
      end
    RBS
    [ruby, rbs]
  end

  def chunks(ruby, rbs)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.evals.values.flatten.map { |chunk| chunk&.source }
    end
  end

  def test_a_block_handed_to_a_module_method_writes_through_a_nested_class_s_memo
    assert_equal ["def post_ids; []; end"], chunks(*project(defined_on: :module, nested: true))
  end

  def test_a_block_handed_to_an_extend_self_method_writes_through_a_nested_class_s_memo
    assert_equal ["def post_ids; []; end"], chunks(*project(defined_on: :instances, nested: true))
  end

  def test_a_block_handed_to_an_extend_self_method_writes_through_a_top_level_class_s_memo
    assert_equal ["def post_ids; []; end"], chunks(*project(defined_on: :instances, nested: false))
  end
end
