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

  CURRENT = DEFINITIONS.sub("  def self.instances", "  def self.current = @main ||= allocate\n  def self.instances")

  CURRENT_RBS = RBS.sub("  self.@instances", "  self.@main: Holder?\n  def self.current: () -> Holder\n  def self.reset: () -> Holder\n  self.@instances") + <<~RBS
    module Touch
      def self.touch: () -> Holder
    end
  RBS

  def chunks(files, rbs = RBS)
    in_tmpdir do
      write("sig/app.rbs", rbs)
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

  def test_a_memo_of_allocate_another_file_runs_keeps_the_class_carried
    touch = "module Touch\n  Holder.current\nend\n"
    assert_equal ["def post_ids; []; end"], chunks({ "a.rb" => CURRENT + RULES, "b.rb" => touch, "c.rb" => MACRO }, CURRENT_RBS)
  end

  def test_a_memo_of_allocate_another_file_runs_through_a_method_keeps_the_class_carried
    touch = "module Touch\n  def self.touch = Holder.current\n  touch\nend\n"
    assert_equal ["def post_ids; []; end"], chunks({ "a.rb" => CURRENT + RULES, "b.rb" => touch, "c.rb" => MACRO }, CURRENT_RBS)
  end

  def test_a_memo_of_allocate_a_call_with_no_known_exit_runs_keeps_the_class_carried
    touch = "module Touch\n  def self.inner(*names) = Holder.current\n  def self.touch(*names) = inner(*names)\n  touch(*%i[a])\nend\n"
    rbs = CURRENT_RBS.sub("def self.touch: () -> Holder", "def self.touch: (*Symbol names) -> Holder\n  def self.inner: (*Symbol names) -> Holder")
    assert_equal ["def post_ids; []; end"], chunks({ "a.rb" => CURRENT + RULES, "b.rb" => touch, "c.rb" => MACRO }, rbs)
  end

  def test_declines_a_memo_of_allocate_another_method_reads
    started = CURRENT.sub("  def self.instances", "  def self.started = @main ? :started : :fresh\n  def self.instances")
    touch = "module Touch\n  Holder.current\nend\n"
    macro = "class Post\n  def self.m(name) = class_eval(\"def \#{Holder.started}_\#{name}; end\")\n  m :posts\nend\n"
    rbs = CURRENT_RBS.sub("  def self.reset: () -> Holder", "  def self.started: () -> Symbol")
    assert_equal [nil], chunks({ "a.rb" => started + RULES, "b.rb" => touch, "c.rb" => macro }, rbs)
  end
end
