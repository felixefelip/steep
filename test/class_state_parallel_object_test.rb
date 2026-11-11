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

  DELETING_RUBY = RUBY
    .sub("  def add(words)\n", "  def delete(entry)\n    super entry\n    @regex_array.delete(to_regex(entry))\n  end\n\n  def add(words)\n")
    .sub("  def singular(rule, replacement)\n", "  def singular(rule, replacement)\n    @uncountables.delete(replacement)\n")

  GENERIC_RBS = RBS
    .sub("class Uncountables < Array[String]", "class Uncountables[T] < Array[T]")
    .sub("  def add: (Array[untyped] words) -> self\n", "  def add: (Array[untyped] words) -> self\n  def delete: (untyped entry) -> untyped\n")
    .gsub(/Uncountables$/, "Uncountables[untyped]")

  SINGULARIZE = <<~RUBY.gsub(/^/, "  ")
    def self.singularize(word)
      result = word.dup
      if word.empty? || rules.uncountables.uncountable?(result)
        result
      else
        rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end
    end
  RUBY

  HANDED_RUBY = RUBY.sub(SINGULARIZE, <<~RUBY.gsub(/^/, "  "))
    def self.singularize(word) = apply(word, rules.singulars)

    def self.apply(word, list, locale = :en)
      result = word.to_s.dup
      if word.empty? || Holder.instance(locale).uncountables.uncountable?(result)
        result
      else
        list.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end
    end
  RUBY

  HANDED_RBS = RBS.sub("  def self.singularize: (String word) -> String\n", "  def self.singularize: (String word) -> String\n  def self.apply: (untyped word, untyped list, ?Symbol locale) -> untyped\n")

  def chunks(name, ruby: RUBY, rbs: RBS)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", format(ruby, name: name))
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

  def test_a_generic_array_subclass_that_deletes_through_super_keeps_its_state
    assert_equal ["def post_ids; []; end"], chunks(":posts", ruby: DELETING_RUBY, rbs: GENERIC_RBS)
    assert_equal ["def fish_ids; []; end"], chunks(":fish", ruby: DELETING_RUBY, rbs: GENERIC_RBS)
  end

  def test_a_rule_deletes_the_pattern_it_matches_from_the_uncountables
    ruby = DELETING_RUBY.sub("  instance(:en).uncountable(\"fish\")\n", "  instance(:en).uncountable(\"fish\")\n  instance(:en).singular(/sh\\z/, \"fish\")\n")

    assert_equal ["def fifish_ids; []; end"], chunks(":fish", ruby: ruby, rbs: GENERIC_RBS)
  end

  def test_declines_a_rule_whose_replacement_is_not_known
    ruby = DELETING_RUBY.sub("  instance(:en).uncountable(\"fish\")\n", "  instance(:en).uncountable(\"fish\")\n  instance(:en).singular(/sh\\z/, ENV.fetch(\"RULE\"))\n")

    assert_equal [nil], chunks(":fish", ruby: ruby, rbs: GENERIC_RBS)
  end

  def test_a_value_not_known_deleted_from_an_empty_array_leaves_it_empty
    ruby = DELETING_RUBY.sub("  instance(:en).uncountable(\"fish\")\n", "  instance(:en).singular(/sh\\z/, ENV.fetch(\"RULE\"))\n  instance(:en).uncountable(\"fish\")\n")

    assert_equal ["def fish_ids; []; end"], chunks(":fish", ruby: ruby, rbs: GENERIC_RBS)
  end

  def test_rules_handed_to_a_method_that_only_reads_them_run_one_by_one
    refute_equal RUBY, HANDED_RUBY
    refute_equal RBS, HANDED_RBS

    assert_equal ["def post_ids; []; end"], chunks(":posts", ruby: HANDED_RUBY, rbs: HANDED_RBS)
    assert_equal ["def fish_ids; []; end"], chunks(":fish", ruby: HANDED_RUBY, rbs: HANDED_RBS)
  end

  def test_declines_rules_handed_to_a_method_that_changes_them
    ruby = HANDED_RUBY
      .sub("    result = word.to_s.dup\n", "    forget(list)\n    result = word.to_s.dup\n")
      .sub("  def self.apply(word, list, locale = :en)\n", "  def self.forget(list) = list.unshift([/posts\\z/, ENV.fetch(\"RULE\")])\n\n  def self.apply(word, list, locale = :en)\n")
    rbs = HANDED_RBS.sub("  def self.apply:", "  def self.forget: (untyped list) -> untyped\n  def self.apply:")
    assert_includes ruby, "    forget(list)\n"
    assert_includes ruby, "def self.forget"

    assert_equal [nil], chunks(":posts", ruby: ruby, rbs: rbs)
  end

  INSTANCE = "  def self.instance(locale = :en) = (instances[locale] ||= Rules.new)\n"

  def with_holder_method(body)
    ruby = RUBY.sub(INSTANCE, INSTANCE + "  #{body}\n")
    rbs = RBS.sub("  def self.instance: (?Symbol locale) -> Rules\n", "  def self.instance: (?Symbol locale) -> Rules\n  def self.lookup: (String word) -> untyped\n")
    refute_equal RUBY, ruby
    refute_equal RBS, rbs
    [ruby, rbs]
  end

  def test_the_memo_read_in_a_block_an_iteration_runs_in_place_keeps_its_state
    ruby, rbs = with_holder_method("def self.lookup(word) = [word].map { |each| instance(:en).uncountables.uncountable?(each) }")

    assert_equal ["def post_ids; []; end"], chunks(":posts", ruby: ruby, rbs: rbs)
  end

  def test_the_memo_read_in_the_block_of_a_string_substitution_keeps_its_state
    ruby, rbs = with_holder_method("def self.lookup(word) = word.to_s.gsub(/x/) { |match| instance(:en).uncountables.uncountable?(match) ? match : match }")

    assert_equal ["def post_ids; []; end"], chunks(":posts", ruby: ruby, rbs: rbs)
  end

  def test_declines_the_memo_read_in_a_block_a_proc_keeps
    ruby, rbs = with_holder_method("def self.lookup(word) = proc { |each| instance(:en).uncountables.uncountable?(each) }")

    assert_equal [nil], chunks(":posts", ruby: ruby, rbs: rbs)
  end
end
