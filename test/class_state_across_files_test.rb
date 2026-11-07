require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassStateAcrossFilesTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  DEFINITIONS = <<~'RUBY'
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

      def self.singularize(word)
        result = word.dup
        instance(:en).singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end
    end

    module Inf
      def self.inflections(locale = :en)
        yield Holder.instance(locale) if block_given?
      end
    end
  RUBY

  RULES = <<~'RUBY'
    module Boot
      Inf.inflections(:en) { |i| i.singular(/s\z/, "") }
    end
  RUBY

  MACRO = <<~'RUBY'
    class Post
      def self.m(name) = class_eval("def #{Holder.singularize(name.to_s)}_ids; []; end")
      m :posts
    end
  RUBY

  WRITER = <<~'RUBY'
    module Late
      Inf.inflections(:en) { |i| i.singular(/ts\z/, "") }
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
      def self.singularize: (String word) -> String
    end
    module Inf
      def self.inflections: (?Symbol locale) ?{ (Rules) -> void } -> untyped
    end
    module Boot
    end
    module Late
    end
    class Post
      def self.m: (Symbol name) -> untyped
    end
  RBS

  def chunks(files)
    in_tmpdir do
      write("sig/app.rbs", RBS)
      files.each { |name, content| write("app/#{name}", content) }
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.evals.values.flatten.map { |chunk| chunk&.source }
    end
  end

  def test_a_macro_in_another_file_reads_what_the_defining_file_left
    assert_equal ["def post_ids; []; end"], chunks("a.rb" => DEFINITIONS + RULES, "z.rb" => MACRO)
  end

  def test_a_macro_in_a_file_named_first_reads_what_the_defining_file_left
    assert_equal ["def post_ids; []; end"], chunks("z.rb" => DEFINITIONS + RULES, "a.rb" => MACRO)
  end

  def test_declines_what_a_file_other_than_the_defining_one_writes
    assert_equal [nil], chunks("a.rb" => DEFINITIONS, "b.rb" => RULES, "c.rb" => MACRO)
  end

  def test_declines_a_class_another_file_writes_after_its_definition
    assert_equal [nil], chunks("a.rb" => DEFINITIONS + RULES, "b.rb" => WRITER, "c.rb" => MACRO)
  end

  def test_declines_a_class_another_file_reopens
    reopened = "class Holder\n  instance(:en).singular(/ts\\z/, \"\")\nend\n"
    assert_equal [nil], chunks("a.rb" => DEFINITIONS + RULES, "b.rb" => reopened, "c.rb" => MACRO)
  end

  def test_declines_a_class_another_file_reopens_in_a_block
    reopened = "[1].each do\n  class Holder\n    instance(:en).singular(/ts\\z/, \"\")\n  end\nend\n"
    assert_equal [nil], chunks("a.rb" => DEFINITIONS + RULES, "b.rb" => reopened, "c.rb" => MACRO)
  end
end
