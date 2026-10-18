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

  TAP_MEMO = '@rules ||= Rules.new.tap { |rules| rules.singular(/s\z/, ""); rules.singular(/ies\z/, "y") }'

  def tapped(memo = TAP_MEMO, body: "")
    source(body: body).sub("@rules ||= Rules.new", memo).sub("  rules.singular(/s\\z/, \"\")\n  rules.singular(/ies\\z/, \"y\")\n", "")
  end

  def test_rules_pushed_in_a_tap_memo_reach_a_macro_in_the_same_body
    assert_equal ["def post_ids; []; end"], chunks(tapped).first
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

  def test_a_reopen_that_only_defines_methods_runs_nothing_first
    rbs = RBS.sub("def self.has_many_like", "def extra: () -> Integer\n  def self.has_many_like")
    reopen = "class Inflector\n  def extra = 1\nend\n"

    assert_equal [["def post_ids; []; end"], ["def category_ids; []; end"]], chunks(reopen + source, rbs: rbs)
  end

  def test_a_second_body_that_runs_code_may_have_built_the_object_first
    reopen = "class Inflector\n  rules.singular(/x\\z/, \"z\")\nend\n"

    assert_equal [[nil], [nil]], chunks(reopen + source)
  end
end
