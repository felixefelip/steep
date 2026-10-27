require_relative "test_helper"

class AccumulatedIvarStateTest < Minitest::Test
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

  def chunks(ruby, rbs: RBS)
    generations(ruby, rbs: rbs)[0]
  end

  def generations(ruby, rbs: RBS)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      count = 0
      runner.singleton_class.prepend(Module.new { define_method(:specialize) { |*args| (count += 1) && super(*args) } })
      log = Steep.log_output
      Steep.log_output = StringIO.new
      begin
        runner.run
        refute_match(/Unexpected error/, Steep.log_output.string)
      ensure
        Steep.log_output = log
      end
      return [runner.evals.values.map { |chunks| chunks.map { |chunk| chunk&.source } }, count]
    end
  end

  RBS = <<~RBS
    class Inflector
      class Rules
        attr_reader singulars: Array[untyped]
        def initialize: () -> Array[untyped]
        def singular: (untyped rule, untyped replacement) -> Array[untyped]
      end

      self.@rules: Inflector::Rules?
      def self.rules: () -> Inflector::Rules
      def self.has_many_like: (Symbol name) -> untyped
    end
  RBS

  def source(body: "", reads: 'rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }', magic: "")
    <<~RUBY
      #{magic}
      class Inflector
        class Rules
          attr_reader :singulars

          def initialize
            @singulars = []
          end

          def singular(rule, replacement)
            @singulars.prepend([rule, replacement])
          end
        end

        def self.rules
          @rules ||= Rules.new
        end

        rules.singular(/s\\z/, "")
        rules.singular(/ies\\z/, "y")
      #{body.gsub(/^/, "  ")}

        def self.has_many_like(name)
          result = name.to_s.dup
          #{reads}
          class_eval "def \#{result}_ids; []; end"
        end

        has_many_like :posts
        has_many_like :categories
      end
    RUBY
  end

  def test_rules_accumulated_in_the_class_body_are_applied_in_order
    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(source)
  end

  def test_a_read_before_any_rule_is_pushed_is_a_hole
    ruby = source.sub("has_many_like :posts\n  has_many_like :categories", "").sub("class Rules", "def self.early = has_many_like(:posts)\n  early\n  class Rules")
    refute_includes chunks(ruby).flatten, "def posts_ids; []; end"
  end

  def test_declines_a_list_something_else_may_change
    {
      "an element changed in a block" => { body: 'rules.singulars.each { |(_, replacement)| replacement << "zz" }' },
      "an element handed to a project method" => { body: "def self.log(text) = text\nrules.singulars.each { |(_, replacement)| log(replacement) }" },
      "the list kept under another name" => { body: "KEPT = rules.singulars" },
      "a method of the class that changes it, called" => { rules: "def clear = @singulars.clear", body: "rules.clear" },
      "a method of the class that changes an element, called" => {
        rules: 'def scramble = @singulars.each { |(_, replacement)| replacement << "zz" }', body: "rules.scramble"
      },
      "a method of the class that changes it, called through a class method" => {
        rules: "def clear = @singulars.clear", body: "def self.reset = rules.clear\nreset"
      },
      "a method of the class that changes it, called through self" => {
        rules: "def clear = @singulars.clear", body: "def self.reset = rules.clear\nself.reset"
      },
      "a method of the class that changes it, called from another class" => {
        rules: "def clear = @singulars.clear", body: "class Helper\n  def self.wipe = Inflector.rules.clear\nend\nHelper.wipe"
      },
      "a push that may not run, made" => {
        rules: "def maybe(rule, replacement, flag) = (@singulars << [rule, replacement] if flag)",
        body: 'rules.maybe(/x\z/, "z", $flag)'
      },
      "a push the project replaced" => { body: "class ::Array\n  def prepend(*) = self\nend" },
      "a core method the block hands an element to, replaced by define_method" => {
        body: '::String.define_method(:start_with?) { |*a| a.first.replace("q"); true }',
        reads: 'rules.singulars.each { |(rule, replacement)| "x".start_with?(replacement); break if result.sub!(rule, replacement) }'
      },
      "a core method the block hands an element to, redefined" => {
        body: "class ::String\n  def start_with?(*) = true\nend",
        reads: 'rules.singulars.each { |(rule, replacement)| "x".start_with?(replacement); break if result.sub!(rule, replacement) }'
      }
    }.each do |label, change|
      ruby = change[:reads] ? source(body: change[:body], reads: change[:reads]) : source(body: change[:body] || "")
      ruby = ruby.sub("    def singular(", "    #{change[:rules]}\n\n    def singular(") if change[:rules]
      rbs = RBS.sub("def singular:", "def clear: () -> Array[untyped]\n    def scramble: () -> Array[untyped]\n    def maybe: (untyped, untyped, untyped) -> untyped\n    def singular:")
                 .sub("  def self.rules:", "  def self.reset: () -> untyped\n  class Helper\n    def self.wipe: () -> untyped\n  end\n  def self.rules:")
      assert_equal [[nil], [nil]], chunks(ruby, rbs: rbs), label
    end
  end

  def test_readers_of_the_same_names_on_another_class_leave_the_list_known
    ruby = source + "\nclass Catalog\n  def rules = []\n  def singulars = []\nend\n\nclass Dumper\n  def self.dump(catalog) = Kernel.puts(catalog.rules, catalog.singulars)\nend\n"
    { "::Catalog" => [["def post_ids; []; end"], ["def category_ids; []; end"]], "untyped" => [[nil], [nil]] }.each do |receiver, expected|
      rbs = RBS + "class Catalog\n  def rules: () -> Array[untyped]\n  def singulars: () -> Array[untyped]\nend\nclass Dumper\n  def self.dump: (#{receiver} catalog) -> untyped\nend\n"

      assert_equal expected, chunks(ruby, rbs: rbs), receiver
    end
  end

  def test_a_block_may_hand_an_element_to_a_core_method_the_project_does_not_redefine
    reads = 'rules.singulars.each { |(rule, replacement)| "x".start_with?(replacement); break if result.sub!(rule, replacement) }'

    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(source(reads: reads))
  end

  def test_a_method_body_is_not_answered_with_what_the_class_body_knew
    ruby = source(reads: "").sub("  rules.singular(/s", "  def self.early = singularize(\"posts\")\n  early\n  rules.singular(/s")
                            .sub("  def self.has_many_like", <<~'RUBY'.gsub(/^/, "  ") + "  def self.has_many_like")
                              def self.singularize(word)
                                result = word.dup
                                rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
                                result
                              end

                            RUBY
    rbs = RBS.sub("def self.has_many_like", "def self.singularize: (String word) -> String\n  def self.early: () -> String\n  def self.has_many_like")

    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)

      refute_includes Steep::Specializations::Runner.run(setup_project).keys, "Inflector.singularize"
    end
  end

  def test_the_rules_reach_a_method_the_macro_calls
    ruby = source(reads: "")
      .sub('class_eval "def #{result}_ids; []; end"', 'class_eval "def #{singularize(name.to_s)}_ids; []; end"')
      .sub("    result = name.to_s.dup\n    \n", "")
      .sub("  def self.has_many_like", <<~'RUBY'.gsub(/^/, "  ") + "  def self.has_many_like")
        def self.singularize(word)
          result = word.dup
          rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
          result
        end

      RUBY
    rbs = RBS.sub("def self.has_many_like", "def self.singularize: (String word) -> String\n  def self.has_many_like")

    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(ruby, rbs: rbs)
  end

  APPLY = <<~'RUBY'
    def apply(word)
      result = word.dup
      @singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
      result
    end
  RUBY

  def walked_inside_rules(apply = APPLY, body: "")
    source(body: body, reads: "result = rules.apply(result)")
      .sub("    def singular(", "#{apply.gsub(/^/, '    ')}\n    def singular(")
  end

  def apply_rbs = RBS.sub("def singular:", "def apply: (String word) -> String\n    def singular:")

  def test_rules_walked_inside_the_object_that_holds_them_are_applied
    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(walked_inside_rules, rbs: apply_rbs)
  end

  def test_declines_a_walk_inside_the_object_that_may_change_it
    {
      "it empties the list" => APPLY.sub("  result\nend", "  @singulars.clear\n  result\nend"),
      "its block changes an element" => APPLY.sub("{ |(rule, replacement)| ", '{ |(rule, replacement)| replacement << "zz"; '),
      "its block keeps an element" => APPLY.sub("{ |(rule, replacement)| ", "{ |(rule, replacement)| $kept = replacement; "),
      "its block hands self on" => APPLY.sub("{ |(rule, replacement)| ", "{ |(rule, replacement)| $kept = self; ")
    }.each do |label, apply|
      assert_equal [[nil], [nil]], chunks(walked_inside_rules(apply), rbs: apply_rbs), label
    end
  end

  def test_declines_a_walk_inside_the_object_with_an_iteration_the_project_replaced
    ruby = walked_inside_rules(body: "class ::Array\n  def each = self\nend")

    assert_equal [[nil], [nil]], chunks(ruby, rbs: apply_rbs)
  end

  IRREGULAR = <<~'RUBY'
    def irregular(singular, plural)
      s0 = singular[0]
      srest = singular[1..-1]
      p0 = plural[0]
      prest = plural[1..-1]

      if s0.upcase == p0.upcase
        singular(/(#{s0})#{srest}$/i, '\1' + srest)
        singular(/(#{p0})#{prest}$/i, '\1' + srest)
      end
    end
  RUBY

  def test_an_irregular_rule_built_from_the_words_it_is_given_is_applied
    ruby = source(body: "rules.irregular(\"person\", \"people\")\nhas_many_like :people")
      .sub("    def singular(") { "#{IRREGULAR.gsub(/^/, '    ')}\n    def singular(" }
    rbs = RBS.sub("def singular:", "def irregular: (untyped singular, untyped plural) -> untyped\n    def singular:")

    assert_equal [["def person_ids; []; end"], ["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(ruby, rbs: rbs)
  end

  def test_an_uncountable_guard_that_matches_patterns_the_object_holds_decides_the_rules
    rbs = <<~RBS
      class Inflector
        class Rules
          attr_reader singulars: Array[untyped]
          @regex_array: Array[untyped]
          def initialize: () -> void
          def singular: (untyped rule, untyped replacement) -> Array[untyped]
          def uncountable: (untyped word) -> Array[untyped]
          def uncountable?: (untyped str) -> bool
        end

        self.@rules: Inflector::Rules?
        def self.rules: () -> Inflector::Rules
        def self.has_many_like: (Symbol name) -> untyped
      end
    RBS
    ruby = <<~'RUBY'
      class Inflector
        class Rules
          attr_reader :singulars

          def initialize
            @singulars = []
            @regex_array = []
          end

          def singular(rule, replacement)
            @singulars.prepend([rule, replacement])
          end

          def uncountable(word)
            @regex_array << /\b#{::Regexp.escape(word)}\Z/i
          end

          def uncountable?(str)
            @regex_array.any? { |regex| regex.match? str }
          end
        end

        def self.rules
          @rules ||= Rules.new
        end

        rules.singular(/s\z/, "")
        rules.uncountable("news")

        def self.has_many_like(name)
          result = name.to_s.dup
          unless rules.uncountable?(result)
            rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
          end
          class_eval "def #{result}_ids; []; end"
        end

        has_many_like :posts
        has_many_like :news
      end
    RUBY

    assert_equal [["def post_ids; []; end"], ["def news_ids; []; end"]], chunks(ruby, rbs: rbs)

    {
      "the block keeps the pattern in $~" => "regex.match(str)",
      "the block changes the element" => 'regex.source.sub!("news", "x")'
    }.each do |label, read|
      assert_equal [[nil], [nil]], chunks(ruby.sub("regex.match? str", read), rbs: rbs), label
    end
  end

  # `ActiveSupport::Inflector::Inflections::Uncountables` (activesupport 8.0.4),
  # kept in an ivar of the object that holds the rules.
  UNCOUNTABLES_RBS = <<~RBS
    class Inflector
      class Uncountables < Array[String]
        @regex_array: Array[untyped]
        def initialize: () -> void
        def <<: (*untyped word) -> self
        def add: (untyped words) -> self
        def uncountable?: (untyped str) -> bool
        private def to_regex: (untyped string) -> Regexp
      end
      class Rules
        attr_reader singulars: Array[untyped]
        attr_reader uncountables: Inflector::Uncountables
        def initialize: () -> void
        def singular: (untyped rule, untyped replacement) -> Array[untyped]
        def uncountable: (*untyped words) -> untyped
        def uncountable?: (untyped word) -> bool
      end

      self.@rules: Inflector::Rules?
      def self.rules: () -> Inflector::Rules
      def self.has_many_like: (Symbol name) -> untyped
    end
  RBS

  def uncountables_source(guard: "rules.uncountables.uncountable?(result)", body: "")
    <<~RUBY
      class Inflector
        class Uncountables < Array
          def initialize
            @regex_array = []
            super
          end

          def <<(*word)
            add(word)
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
            def to_regex(string)
              /\\b\#{::Regexp.escape(string)}\\Z/i
            end
        end

        class Rules
          attr_reader :singulars, :uncountables

          def initialize
            @singulars = []
            @uncountables = Uncountables.new
          end

          def singular(rule, replacement)
            @singulars.prepend([rule, replacement])
          end

          def uncountable(*words)
            @uncountables << words
          end

          def uncountable?(word)
            @uncountables.uncountable?(word)
          end
        end

        def self.rules
          @rules ||= Rules.new
        end

        rules.singular(/s\\z/, "")
        rules.uncountable("news")
      #{body.gsub(/^/, "  ")}

        def self.has_many_like(name)
          result = name.to_s.dup
          unless #{guard}
            rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
          end
          class_eval "def \#{result}_ids; []; end"
        end

        has_many_like :posts
        has_many_like :news
      end
    RUBY
  end

  def test_an_uncountable_list_kept_in_an_object_of_its_own_decides_the_rules
    expected = [["def post_ids; []; end"], ["def news_ids; []; end"]]

    assert_equal expected, chunks(uncountables_source, rbs: UNCOUNTABLES_RBS), "through the reader"
    assert_equal expected, chunks(uncountables_source(guard: "rules.uncountable?(result)"), rbs: UNCOUNTABLES_RBS), "through the holder"
  end

  def test_declines_an_uncountable_list_changed_where_its_holder_cannot_see
    {
      "through the reader" => 'rules.uncountables << "posts"',
      "through another name" => "kept = rules.uncountables\nkept << \"posts\""
    }.each do |label, body|
      assert_equal [[nil], [nil]], chunks(uncountables_source(body: body), rbs: UNCOUNTABLES_RBS), label
    end
  end

  TAP_MEMO = '@rules ||= Rules.new.tap { |rules| rules.singular(/s\z/, ""); rules.singular(/ies\z/, "y") }'

  def tapped(memo = TAP_MEMO, body: "")
    source(body: body).sub("@rules ||= Rules.new", memo).sub("  rules.singular(/s\\z/, \"\")\n  rules.singular(/ies\\z/, \"y\")\n", "")
  end

  def test_rules_pushed_in_a_tap_memo_reach_a_macro_in_the_same_body
    assert_equal ["def post_ids; []; end"], chunks(tapped).first
  end

  def test_a_rule_whose_pattern_interpolates_literals_is_applied_as_the_pattern_written_out
    memo = TAP_MEMO.sub('/ies\z/', '/#{"ie"}#{:s}\z/')

    assert_equal chunks(tapped), chunks(tapped(memo))
  end

  def test_a_jump_inside_a_loop_of_the_tap_block_leaves_only_that_loop
    memo = TAP_MEMO.sub("{ |rules| ", "{ |rules| [1].each { break }; ")

    assert_equal ["def post_ids; []; end"], chunks(tapped(memo)).first
  end

  def test_rules_pushed_after_a_tap_memo_come_first
    ruby = tapped(body: 'rules.singular(/ories\z/, "orium")')

    assert_equal [["def post_ids; []; end"], ["def categorium_ids; []; end"]], chunks(ruby)
  end

  def test_declines_a_tap_memo_whose_object_another_name_may_reach
    {
      "the block keeps it" => TAP_MEMO.sub("{ |rules| ", "{ |rules| $kept = rules; "),
      "the block breaks" => TAP_MEMO.sub(" }", "; break rules }"),
      "the block may leave early" => TAP_MEMO.sub('rules.singular(/ies', 'next if $flag; rules.singular(/ies'),
      "the block may run again" => TAP_MEMO.sub(" }", "; redo if $flag }"),
      "a call that answers its block" => TAP_MEMO.sub(".tap {", ".then {").sub(" }", "; rules }")
    }.each do |label, memo|
      assert_equal [[nil], [nil]], chunks(tapped(memo)), label
    end
  end

  def test_declines_a_tap_the_project_replaces
    replaced = "def tap\n  yield self\n  self.class.new\nend"
    {
      "in Kernel" => ["module ::Kernel\n#{replaced.gsub(/^/, '  ')}\nend", RBS],
      "in the class" => ["class Rules\n#{replaced.gsub(/^/, '  ')}\nend", RBS.sub("def singular:", "def tap: () { (self) -> void } -> self\n    def singular:")]
    }.each do |label, (body, rbs)|
      assert_equal [[nil], [nil]], chunks(tapped(body: body), rbs: rbs), label
    end
  end

  def test_rules_a_module_builds_with_tap_reach_another_class_through_the_object_that_holds_them
    rbs = <<~RBS
      class Rules
        attr_reader singulars: Array[untyped]
        def initialize: () -> void
        def singular: (untyped rule, untyped replacement) -> Array[untyped]
        def apply: (String word) -> String
      end
      module Inflector
        self.@rules: Rules?
        def self.rules: () -> Rules
        def self.singularize: (String word) -> String
      end
      class Post
        def self.has_many_like: (Symbol name) -> untyped
      end
    RBS
    ruby = <<~RUBY
      class Rules
        attr_reader :singulars

        def initialize
          @singulars = []
        end

        def singular(rule, replacement)
          @singulars.prepend([rule, replacement])
        end

      #{APPLY.gsub(/^/, "  ")}end

      module Inflector
        def self.rules
          #{TAP_MEMO}
        end

        def self.singularize(word) = rules.apply(word)
      end

      class Post
        def self.has_many_like(name) = class_eval "def \#{Inflector.singularize(name.to_s)}_ids; []; end"

        has_many_like :posts
        has_many_like :categories
      end
    RUBY

    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(ruby, rbs: rbs)
  end

  IRREGULAR_RBS = RBS.sub("def singular:", "def irregular: (untyped, untyped) -> Array[untyped]\n    def singular:")

  def with_irregular(ruby, body)
    ruby.sub("    def singular(", "    def irregular(a, b)\n#{body.gsub(/^/, "      ")}\n    end\n\n    def singular(")
  end

  def test_a_chain_of_rules_settles_in_as_many_generations_however_long_it_is
    {
      'rules.singular(/zz%d\\z/, "q")' => "singular(a, b)",
      'rules.irregular("zz%d", "q")' => "singular(a, b)\nsingular(b, a)"
    }.each do |push, irregular|
      short, long = [1, 12].map do |count|
        generations(with_irregular(source(body: (1..count).map { |i| push % i }.join("\n")), irregular), rbs: IRREGULAR_RBS)
      end

      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], long[0], push
      assert_equal short[1], long[1], push
    end
  end

  def test_rules_written_through_a_method_of_the_object_that_calls_another_on_self
    ["singular(a, b)", "self.singular(a, b)", "singular(a, b)\nsingular(b, a)"].each do |irregular|
      ruby = with_irregular(source(body: 'rules.irregular("posts", "article")'), irregular)

      assert_equal [["def article_ids; []; end"], ["def category_ids; []; end"]], chunks(ruby, rbs: IRREGULAR_RBS), irregular
    end
  end

  YIELD_RBS = RBS.sub("def self.rules:", "def self.inflections: () { (Inflector::Rules) -> void } -> void\n  def self.rules:")
                 .sub("  def self.has_many_like", "  class Other\n    def self.boot: () -> void\n  end\n  def self.has_many_like")

  YIELD_BLOCK = 'inflections { |inflect| inflect.singular(/posts\z/, "article") }'

  def yielded(inflections: "def self.inflections = yield(rules)", call: YIELD_BLOCK)
    chunks(source(body: "#{inflections}\n#{call}"), rbs: YIELD_RBS)
  end

  def test_rules_a_block_writes_through_the_object_a_method_yields
    {
      "a yield" => "def self.inflections = yield(rules)",
      "a yield under block_given?" => "def self.inflections\n  yield rules if block_given?\nend"
    }.each do |label, inflections|
      assert_equal [["def article_ids; []; end"], ["def category_ids; []; end"]], yielded(inflections: inflections), label
    end
  end

  def test_a_method_that_yields_the_memo_and_is_not_called_leaves_it_followed
    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], yielded(call: "")
  end

  def test_a_block_whose_writes_settle_into_no_one_state_leaves_the_memo_unknown
    call = 'inflections { |inflect| inflect.singular(/posts\z/, "article") if "x".frozen? }'

    assert_equal [[nil], [nil]], yielded(call: call)
  end

  def test_declines_a_memo_yielded_alongside_another_value
    rbs = YIELD_RBS.sub("{ (Inflector::Rules) -> void }", "{ (Inflector::Rules, Integer) -> void }")

    assert_equal [[nil], [nil]], chunks(source(body: "def self.inflections = yield(rules, 1)\n#{YIELD_BLOCK}"), rbs: rbs)
  end

  def test_declines_a_memo_yielded_from_inside_a_block
    assert_equal [[nil], [nil]], yielded(inflections: "def self.inflections = [1].each { yield rules }")
  end

  def test_a_block_given_the_project_replaces_is_not_decided
    replaced = "module ::Kernel\n  def block_given? = false\nend\n"

    assert_equal [[nil], [nil]], chunks(replaced + source(body: "def self.inflections\n  yield rules if block_given?\nend\n#{YIELD_BLOCK}"), rbs: YIELD_RBS)
  end

  def test_declines_a_yielded_memo_whose_block_is_not_followed
    {
      "a block reading a local of its own scope" => "replacement = \"article\"\ninflections { |inflect| inflect.singular(/posts\\z/, replacement) }",
      "a block calling on its own self" => "inflections { |inflect| inflect.singular(/posts\\z/, name.to_s) }",
      "a block that breaks" => "inflections { |inflect| break }",
      "a block handed on" => "handed = proc { |inflect| inflect.singular(/posts\\z/, \"article\") }\ninflections(&handed)",
      "a call from another class" => "class Other\n  def self.boot = Inflector.inflections { |inflect| inflect.singular(/posts\\z/, \"article\") }\nend"
    }.each do |label, call|
      assert_equal [[nil], [nil]], yielded(call: call), label
    end
  end

  HANDED_RBS = RBS.sub("def self.rules:", "def self.current: (Symbol locale) -> Inflector::Rules\n  def self.wipe: () -> untyped\n  def self.rules:")
                  .sub("def singular:", "def clear: () -> Array[untyped]\n    def singular:")

  HANDED_READS = 'current(:en).singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }'

  def handed_back(current, body: "", rules: nil)
    ruby = source(body: "#{current}\n#{body}", reads: HANDED_READS)
    ruby = ruby.sub("    def singular(", "    #{rules}\n\n    def singular(") if rules
    chunks(ruby, rbs: HANDED_RBS)
  end

  def test_a_method_whose_every_value_is_the_memo_reads_as_the_memo
    {
      "its whole body" => "def self.current(locale) = rules",
      "a return from a loop and its last value" => "def self.current(locale)\n  [locale, :en].each { |k| return rules if k == :en }\n  rules\nend"
    }.each do |label, current|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], handed_back(current), label
    end
  end

  def test_a_method_that_yields_the_memo_and_hands_it_back_without_a_block_reads_the_rules_the_block_wrote
    rbs = YIELD_RBS.sub("def self.inflections: () { (Inflector::Rules) -> void } -> void", "def self.inflections: () { (Inflector::Rules) -> void } -> void\n                      | () -> Inflector::Rules")
    inflections = "def self.inflections\n  if block_given?\n    yield rules\n  else\n    rules\n  end\nend"
    reads = 'inflections.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }'

    assert_equal [["def article_ids; []; end"], ["def category_ids; []; end"]], chunks(source(body: "#{inflections}\n#{YIELD_BLOCK}", reads: reads), rbs: rbs)
  end

  def test_declines_a_memo_changed_through_a_method_that_hands_it_back
    {
      "in a statement of the class body" => "current(:en).clear",
      "in a method" => "def self.wipe = current(:en).clear",
      "kept under another name" => "KEPT = current(:en)"
    }.each do |label, body|
      assert_equal [[nil], [nil]], handed_back("def self.current(locale) = rules", body: body, rules: "def clear = @singulars.clear"), label
    end
  end

  KEYED_RBS = <<~RBS
    class Inflector
      class Rules
        attr_reader singulars: Array[untyped]
        def initialize: () -> Array[untyped]
        def singular: (untyped rule, untyped replacement) -> Array[untyped]
        def clear: () -> Array[untyped]
      end

      self.@instances: Hash[Symbol, Inflector::Rules]?
      def self.instances: () -> Hash[Symbol, Inflector::Rules]
      def self.instance: (Symbol locale) -> Inflector::Rules
      def self.wipe: () -> untyped
      def self.has_many_like: (Symbol name) -> untyped
    end
  RBS

  def keyed(body: "", reads: "instance(:en)", writes: "instance(:en)", rules: "")
    <<~RUBY
      class Inflector
        class Rules
          attr_reader :singulars

          def initialize
            @singulars = []
          end

          def singular(rule, replacement)
            @singulars.prepend([rule, replacement])
          end
          #{rules}
        end

        def self.instances = @instances ||= {}
        def self.instance(locale) = (instances[locale] ||= Rules.new)

        #{writes}.singular(/s\\z/, "")
        #{writes}.singular(/ies\\z/, "y")
      #{body.gsub(/^/, "  ")}

        def self.has_many_like(name)
          result = name.to_s.dup
          #{reads}.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
          class_eval "def \#{result}_ids; []; end"
        end

        has_many_like :posts
        has_many_like :categories
      end
    RUBY
  end

  def test_an_object_a_hash_memo_keeps_under_a_literal_key_holds_the_rules_written_to_it
    {
      "read through the method that stores it" => keyed,
      "read by key" => keyed(reads: "instances[:en]"),
      "written by key" => keyed(writes: "instances[:en]", body: "").sub("  instances[:en].singular(/s", "  instances[:en] = Rules.new\n  instances[:en].singular(/s")
    }.each do |label, ruby|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(ruby, rbs: KEYED_RBS), label
    end
  end

  def held_by_ivar(rbs) = rbs.sub("self.@instances: Hash[Symbol, Inflector::Rules]?\n  def self.instances: () -> Hash[Symbol, Inflector::Rules]\n", "self.@instances: Hash[Symbol, Inflector::Rules]\n")

  BY_IVAR_RBS = KEYED_RBS.sub("def self.wipe:", "def self.instance_or_fallback: (Symbol locale) -> Inflector::Rules\n  def self.wipe:")

  def read_by_ivar(ruby, born: "@instances = {}")
    held = ruby.sub("  def self.instances = @instances ||= {}\n  def self.instance(locale) = (instances[locale] ||= Rules.new)\n", <<~RUBY.gsub(/^/, "  "))
      #{born}
      def self.instance(locale) = (@instances[locale] ||= Rules.new)
    RUBY
    held.gsub(/(?<![@.\w])instances\[/, "@instances[")
  end

  def by_ivar(born: "@instances = {}", reads: "instance(:en)", body: "") = read_by_ivar(keyed(reads: reads, body: body), born: born)

  def test_a_hash_an_ivar_holds_directly_keeps_its_objects
    fallback = "def self.instance_or_fallback(locale) = @instances.key?(locale) ? @instances[locale] : instance(locale)"
    {
      "born in the class body, read through the method that stores it" => by_ivar,
      "born in the class body, read by key" => by_ivar(reads: "@instances[:en]"),
      "born in the class body, read through a fallback" => by_ivar(reads: "instance_or_fallback(:en)", body: fallback),
      "born by a memo" => by_ivar(born: "@instances ||= {}")
    }.each do |label, ruby|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(ruby, rbs: held_by_ivar(BY_IVAR_RBS)), label
    end
  end

  def test_declines_a_hash_an_ivar_holds_that_something_else_may_change
    rbs = held_by_ivar(BY_IVAR_RBS).sub("def self.wipe:", "def self.reset: () -> untyped\n  def self.all: () -> untyped\n  class Other\n    def self.go: () -> untyped\n  end\n  def self.wipe:")
    {
      "set again by a method" => by_ivar(body: "def self.reset = (@instances = {})\nreset"),
      "set again by a method another class calls" => by_ivar(
        body: "def self.reset = (@instances = {})\nclass Other\n  def self.go = Inflector.reset\nend\nOther.go"
      ),
      "set first by a method" => by_ivar(born: "def self.reset = (@instances = {})\nreset"),
      "stored again by a method" => by_ivar(body: "def self.reset = (@instances[:en] = Rules.new)\nreset"),
      "stored again by a method another class calls" => by_ivar(
        body: "def self.reset = (@instances[:en] = Rules.new)\nclass Other\n  def self.go = Inflector.reset\nend\nOther.go"
      ),
      "handed out" => by_ivar(body: "def self.all = @instances\nall.each_value(&:clear)"),
      "deleted from" => by_ivar(body: "@instances.delete(:en)")
    }.each do |label, ruby|
      written = chunks(ruby, rbs: rbs).flatten
      refute_includes written, "def post_ids; []; end", label
      refute_includes written, "def category_ids; []; end", label
    end
  end

  def forwarding_map(extra = "")
    <<~RUBY
      class Map
        def initialize
          @backend = {}
        end

        def [](key) = @backend[key]

        def []=(key, value)
          @backend[key] = value
        end

        def key?(key) = @backend.key?(key)
      #{extra.gsub(/^/, "  ")}
      end
    RUBY
  end

  def forwarding_map_rbs(rbs, extra = "")
    <<~RBS + held_by_ivar(rbs).sub("self.@instances: Hash[Symbol, Inflector::Rules]", "self.@instances: Map")
      class Map
        @backend: Hash[Symbol, Inflector::Rules]
        def initialize: () -> void
        def []: (Symbol key) -> Inflector::Rules?
        def []=: (Symbol key, Inflector::Rules value) -> Inflector::Rules
        def key?: (Symbol key) -> bool
        #{extra}
      end
    RBS
  end

  def by_map(born: "@instances = Map.new", reads: "instance(:en)", body: "", map: "") = forwarding_map(map) + by_ivar(born: born, reads: reads, body: body)

  def test_a_hash_an_object_an_ivar_holds_keeps_its_objects
    fallback = "def self.instance_or_fallback(locale) = @instances.key?(locale) ? @instances[locale] : instance(locale)"
    {
      "read through the method that stores it" => by_map,
      "read by key" => by_map(reads: "@instances[:en]"),
      "read through a fallback" => by_map(reads: "instance_or_fallback(:en)", body: fallback),
      "born by a memo" => by_map(born: "@instances ||= Map.new"),
      "next to a store through another forwarder" => by_map(map: "def put(key, value) = (@backend[key] = value)", body: "def self.preset = @instances.put(:fr, Rules.new)")
    }.each do |label, ruby|
      rbs = forwarding_map_rbs(BY_IVAR_RBS.sub("def self.wipe:", "def self.preset: () -> untyped\n  def self.wipe:"), "def put: (Symbol key, Inflector::Rules value) -> Inflector::Rules")
      rbs = rbs.sub("self.@instances: Map", "self.@instances: Map?") if label == "born by a memo"
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(ruby, rbs: rbs), label
    end
  end

  def test_declines_a_hash_an_object_an_ivar_holds_that_something_else_may_change
    methods = "def self.reset: () -> untyped\n  def self.all: () -> untyped\n  class Other\n    def self.go: () -> untyped\n  end\n  def self.wipe:"
    map_methods = "def put: (Symbol key, Inflector::Rules value) -> Inflector::Rules\n  def clear: () -> untyped\n  def taint: () -> untyped"
    rbs = forwarding_map_rbs(BY_IVAR_RBS.sub("def self.wipe:", methods), map_methods)
    put = "def put(key, value) = (@backend[key] = value)"
    rewrite = "def clear = (@backend = {})"
    taint = "def taint = @backend[:en].singular(/posts\\z/, \"article\")"
    through_other = "class Other\n  def self.go = Inflector.reset\nend\nOther.go"
    {
      "set again by a method" => by_map(body: "def self.reset = (@instances = Map.new)\nreset"),
      "stored again by a method" => by_map(body: "def self.reset = (@instances[:en] = Rules.new)\nreset"),
      "stored again through another forwarder by a method another class calls" => by_map(map: put, body: "def self.reset = @instances.put(:en, Rules.new)\n#{through_other}"),
      "rewritten by a method of the object" => by_map(map: rewrite, body: "def self.reset = @instances.clear\n#{through_other}"),
      "an element changed by a method of the object another class calls" => by_map(map: taint, body: "def self.reset = @instances.taint\n#{through_other}"),
      "handed out" => by_map(body: "def self.all = @instances\nall[:en].clear")
    }.each do |label, ruby|
      written = chunks(ruby, rbs: rbs).flatten
      refute_includes written, "def post_ids; []; end", label
      refute_includes written, "def category_ids; []; end", label
    end
  end

  ACROSS_RBS = KEYED_RBS.sub("  def self.has_many_like: (Symbol name) -> untyped\nend\n", <<~RBS)
      def self.singularize: (String word) -> String
    end
    class Post
      def self.has_many_like: (Symbol name) -> untyped
      def self.reset: () -> untyped
    end
    class Helper
      def self.go: () -> untyped
    end
    class Middle
      def self.go: () -> untyped
    end
    class Stamp
      def to_str: () -> String
      def to_a: () -> Array[untyped]
      def to_int: () -> Integer
    end
  RBS

  def keyed_across(reads: "instance(:en)", body: "", post: "", outside: "")
    keyed(body: body).sub(/  def self\.has_many_like.*\z/m, <<~RUBY)
        def self.singularize(word)
          result = word.dup
          #{reads}.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
          result
        end
      end

      #{outside}
      class Post
        def self.has_many_like(name) = class_eval("def \#{Inflector.singularize(name.to_s)}_ids; []; end")
      #{post.gsub(/^/, "  ")}
        has_many_like :posts
        has_many_like :categories
      end
    RUBY
  end

  def test_an_object_a_hash_memo_keeps_holds_its_rules_for_a_macro_of_another_class
    {
      "read through the method that stores it" => keyed_across,
      "read by key" => keyed_across(reads: "instances[:en]")
    }.each do |label, ruby|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(ruby, rbs: ACROSS_RBS), label
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(read_by_ivar(ruby), rbs: held_by_ivar(ACROSS_RBS)), "#{label}, held by the ivar"
    end
  end

  def test_a_macro_of_another_class_never_reads_rules_a_store_since_replaced
    wipe = "def self.wipe = (instances[:en] = Rules.new)"
    {
      "through a method of its own" => keyed_across(body: wipe, post: "def self.reset = Inflector.wipe\nreset"),
      "through classes handed nothing of it" => keyed_across(
        body: wipe, post: "Helper.go", outside: "class Middle\n  def self.go = Inflector.wipe\nend\n\nclass Helper\n  def self.go = Middle.go\nend\n"
      ),
      "by key from another class" => keyed_across(post: "def self.reset = (Inflector.instances[:en] = Inflector::Rules.new)\nreset"),
      "through a conversion the runtime calls" => keyed_across(body: wipe, post: '"a" + Stamp.new', outside: "class Stamp\n  def to_str = (Inflector.wipe && \"\")\nend\n"),
      "through a splat" => keyed_across(body: wipe, post: "[*Stamp.new]", outside: "class Stamp\n  def to_a = (Inflector.wipe && [])\nend\n"),
      "through an index the runtime converts" => keyed_across(body: wipe, post: "[1][Stamp.new]", outside: "class Stamp\n  def to_int = (Inflector.wipe && 0)\nend\n")
    }.each do |label, ruby|
      refute_includes chunks(ruby, rbs: ACROSS_RBS).flatten, "def post_ids; []; end", label
      next if ruby.include?("Inflector.instances")

      refute_includes chunks(read_by_ivar(ruby), rbs: held_by_ivar(ACROSS_RBS)).flatten, "def post_ids; []; end", "#{label}, held by the ivar"
    end
  end

  def test_an_object_stored_again_under_the_key_is_never_answered_with_the_rules_of_the_one_it_replaced
    rbs = KEYED_RBS.sub("def self.wipe:", "def self.reset: () -> untyped\n    class Other\n      def self.go: () -> untyped\n    end\n    def self.wipe:")
    {
      "by a statement of the class body" => "def self.reset = (instances[:en] = Rules.new)\nreset",
      "by a method another class calls" => "def self.reset = (instances[:en] = Rules.new)\nclass Other\n  def self.go = Inflector.reset\nend\nOther.go"
    }.each do |label, body|
      written = chunks(keyed(body: body), rbs: rbs).flatten
      refute_includes written, "def post_ids; []; end", label
      refute_includes written, "def category_ids; []; end", label
    end
  end

  def test_declines_an_object_a_hash_memo_keeps_that_something_else_may_change
    {
      "handed out by a read of every value" => keyed(body: "instances.values.each(&:clear)"),
      "changed in a method" => keyed(body: "def self.wipe = instance(:en).clear", rules: "def clear = (@singulars = [])"),
      "kept under another name" => keyed(body: "KEPT = instance(:en)"),
      "stored from a local that changes it afterwards" => keyed(writes: "kept").sub("  kept.singular(/s", "  kept = Rules.new\n  instances[:en] = kept\n  kept.singular(/s")
    }.each do |label, ruby|
      assert_equal [[nil], [nil]], chunks(ruby, rbs: KEYED_RBS), label
    end
  end

  YIELDED_RBS = KEYED_RBS.sub("def self.wipe:", "def self.inflections: (Symbol locale) ?{ (Inflector::Rules) -> void } -> void\n    class Other\n      def self.boot: () -> void\n    end\n    def self.wipe:")

  def yielded_element(call, inflections: "def self.inflections(locale)\n  yield instance(locale) if block_given?\nend")
    keyed(body: "#{inflections}\n#{call}", writes: "instance(:en)").sub(/^  instance\(:en\)\.singular.*\n  instance\(:en\)\.singular.*\n/, "")
  end

  YIELDED_BLOCK = 'inflections(:en) { |inflect| inflect.singular(/s\z/, ""); inflect.singular(/ies\z/, "y") }'

  def test_rules_a_block_writes_through_an_element_a_method_yields
    {
      "through the method that stores it" => "def self.inflections(locale)\n  yield instance(locale) if block_given?\nend",
      "by key" => "def self.inflections(locale)\n  instances[locale] ||= Rules.new\n  yield instances[locale]\nend"
    }.each do |label, inflections|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(yielded_element(YIELDED_BLOCK, inflections: inflections), rbs: YIELDED_RBS), label
    end
  end

  def test_declines_an_element_yielded_to_a_block_that_is_not_followed
    {
      "a block reading a local of its own scope" => "replacement = \"y\"\ninflections(:en) { |inflect| inflect.singular(/ies\\z/, replacement) }",
      "a call from another class" => "class Other\n  def self.boot = Inflector.inflections(:en) { |inflect| inflect.singular(/ies\\z/, \"y\") }\nend",
      "a block handed on" => "handed = proc { |inflect| inflect.singular(/ies\\z/, \"y\") }\ninflections(:en, &handed)"
    }.each do |label, call|
      assert_equal [[nil], [nil]], chunks(yielded_element(call), rbs: YIELDED_RBS), label
    end
  end

  HANDING_RBS = KEYED_RBS.sub("def self.wipe:", "def self.instance_or_fallback: (Symbol locale) -> Inflector::Rules\n    def self.reset: () -> untyped\n    def self.wipe:")

  def handing(body, rules: "") = keyed(body: body, reads: "instance_or_fallback(:en)", rules: rules)

  def test_a_method_whose_every_returned_value_is_an_element_hands_that_element_back
    {
      "under a fixed key" => "def self.instance_or_fallback(locale) = instances[:en]",
      "through the method that stores it" => "def self.instance_or_fallback(locale) = instance(locale)",
      "a conditional over its keys" => "def self.instance_or_fallback(locale) = instances.key?(locale) ? instances[locale] : instance(locale)",
      "an early return" => "def self.instance_or_fallback(locale)\n  return instances[locale] if locale == :en\n  instance(locale)\nend",
      "either of two" => "def self.instance_or_fallback(locale) = instances[locale] || instance(locale)"
    }.each do |label, body|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(handing(body), rbs: HANDING_RBS), label
    end
  end

  def test_an_element_read_inside_parentheses_or_a_conditional_is_followed
    {
      "parentheses" => "(instances[:en])",
      "a call in parentheses" => "(instance(:en))",
      "a conditional" => "(instances.key?(:en) ? instances[:en] : instance(:en))"
    }.each do |label, reads|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(keyed(reads: reads), rbs: KEYED_RBS), label
    end
  end

  def test_declines_a_method_that_may_hand_back_anything_but_an_element
    {
      "an object of its own" => handing("def self.instance_or_fallback(locale) = locale == :en ? instances[locale] : Rules.new"),
      "an element changed through it" => handing("def self.instance_or_fallback(locale) = instance(locale)\ninstance_or_fallback(:en).clear", rules: "def clear = (@singulars = [])")
    }.each do |label, ruby|
      assert_equal [[nil], [nil]], chunks(ruby, rbs: HANDING_RBS), label
    end
  end

  def test_asking_for_a_key_decides_which_element_a_method_hands_back
    {
      "a key the hash holds" => "def self.instance_or_fallback(locale) = instances.key?(:en) ? instances[:en] : instances[:pt]",
      "a key it does not" => "def self.instance_or_fallback(locale) = instances.key?(:pt) ? instances[:pt] : instance(locale)"
    }.each do |label, body|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(handing(body), rbs: HANDING_RBS), label
    end
  end

  WALK = "def self.instance_or_fallback(locale)\n  %s.each do |k|\n    return instances[k] if instances.key?(k)\n  end\n  instance(locale)\nend"

  def test_a_walk_over_a_known_list_hands_back_the_first_element_the_hash_holds
    {
      "the locale itself" => format(WALK, "[locale, :en]"),
      "past a key it does not hold" => format(WALK, "[:pt, locale]"),
      "past every key, to the method that stores it" => format(WALK, "[:pt, :fr]")
    }.each do |label, body|
      assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(handing(body), rbs: HANDING_RBS), label
    end
  end

  def test_a_walk_hands_back_an_element_held_ahead_of_the_locale
    body = "#{format(WALK, "[:pt, locale]")}\ninstance(:pt).singular(/s\\z/, \"o\")"

    assert_equal [["def posto_ids; []; end"], ["def categorieo_ids; []; end"]], chunks(handing(body), rbs: HANDING_RBS)
  end

  def test_declines_a_walk_whose_return_is_left_open
    body = "def self.instance_or_fallback(locale)\n  [:pt, locale].each { |k| return instances[k] if [true, false].sample }\n  instance(locale)\nend"

    assert_equal [[nil], [nil]], chunks(handing(body), rbs: HANDING_RBS)
  end

  KEYED_MEMO_RBS = HANDING_RBS.sub("class Inflector\n", <<~RBS)
    class Fallbacks < Hash[Symbol, Array[Symbol]]
      @default: Symbol
      def initialize: () -> void
      def []: (Symbol locale) -> Array[Symbol]
      def reset: () -> Fallbacks
      def compute: (Symbol locale) -> Array[Symbol]
    end
    module Locales
      self.@fallbacks: Fallbacks?
      def self.fallbacks: () -> Fallbacks
    end
    class Other
      def self.go: () -> untyped
    end
    class Inflector
  RBS

  def keyed_memo(extra: "", outside: "", initialize: "@default = :en", read: "")
    fallbacks = <<~RUBY
      class Fallbacks < Hash
        def initialize
      #{initialize.gsub(/^/, "    ")}
        end

        def [](locale)
          raise ArgumentError if locale.nil?
      #{read.gsub(/^/, "    ")}
          locale = locale.to_sym
          super || store(locale, compute(locale))
        end

        def compute(locale) = [locale, @default]
      #{extra.gsub(/^/, "  ")}
      end

      module Locales
        def self.fallbacks = @fallbacks ||= Fallbacks.new
      end
    RUBY
    fallbacks + handing(format(WALK, "Locales.fallbacks[locale]")) + outside
  end

  def test_a_hash_s_own_keyed_memo_answers_what_it_stores
    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(keyed_memo, rbs: KEYED_MEMO_RBS)
  end

  def test_declines_a_keyed_memo_whose_entries_something_else_changes
    {
      "from another class" => keyed_memo(outside: "\nclass Other\n  def self.go = Locales.fallbacks.clear\nend\n"),
      "through a method of its own" => keyed_memo(extra: "def reset = clear", outside: "\nclass Other\n  def self.go = Locales.fallbacks.reset\nend\n"),
      "built outside a memo" => keyed_memo(outside: "\nclass Other\n  def self.go = Fallbacks.new\nend\n"),
      "built in an instance method named like the memo" => keyed_memo(outside: "\nmodule Locales\n  def fallbacks = Fallbacks.new\nend\n"),
      "cleared before it stores" => keyed_memo(read: "clear"),
      "with a default" => keyed_memo(initialize: "super([:pt])\n@default = :en"),
      "with a default of its own" => keyed_memo(extra: "def default(_key = nil) = [:pt]")
    }.each do |label, ruby|
      assert_equal [[nil], [nil]], chunks(ruby, rbs: KEYED_MEMO_RBS), label
    end
  end

  def test_a_method_handing_back_an_element_stored_again_never_answers_the_one_it_replaced
    written = chunks(handing("def self.instance_or_fallback(locale) = instance(locale)\ndef self.reset = (instances[:en] = Rules.new)\nreset"), rbs: HANDING_RBS).flatten

    refute_includes written, "def post_ids; []; end"
    refute_includes written, "def category_ids; []; end"
  end

  def test_a_reopen_that_only_defines_methods_runs_nothing_first
    rbs = RBS.sub("def self.has_many_like", "def extra: () -> Integer\n  def self.has_many_like")
    reopen = "class Inflector\n  def extra = 1\nend\n"

    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(reopen + source, rbs: rbs)
  end

  def test_a_second_body_that_runs_code_may_have_built_the_object_first
    reopen = "class Inflector\n  rules.singular(/x\\z/, \"z\")\nend\n"

    assert_equal [[nil], [nil]], chunks(reopen + source)
  end

  BOX_RBS = <<~RBS
    class Box
      @entries: Hash[Symbol, Symbol]
      def initialize: () -> void
      def put: (Symbol key, Symbol value) -> Symbol
      def get: (Symbol key) -> Symbol?
    end
    class Inflector
      self.@box: Box?
      def self.box: () -> Box
      def self.has_many_like: (Symbol name) -> untyped
    end
    class Elsewhere
      def self.run: () -> untyped
    end
  RBS

  def box_source(elsewhere: "")
    <<~RUBY
      class Box
        def initialize
          @entries = {}
        end

        def put(key, value)
          @entries[key] = value
        end

        def get(key)
          @entries[key]
        end
      end

      class Inflector
        def self.box = @box ||= Box.new

        box.put(:posts, :post)
        box.put(:news, :news)

        def self.has_many_like(name)
          class_eval "def \#{box.get(name)}_ids; []; end"
        end

        has_many_like :posts
        has_many_like :news
      end

      class Elsewhere
        def self.run
          #{elsewhere}
        end
      end
    RUBY
  end

  def test_a_hash_the_initialize_of_a_memo_s_object_sets_keeps_what_the_class_body_stores
    assert_equal [["def post_ids; []; end"], ["def news_ids; []; end"]], chunks(box_source, rbs: BOX_RBS)
  end

  def test_declines_a_hash_in_a_memo_s_object_that_another_class_stores_into
    assert_equal [[nil], [nil]], chunks(box_source(elsewhere: "Inflector.box.put(:posts, :other)"), rbs: BOX_RBS)
  end
end
