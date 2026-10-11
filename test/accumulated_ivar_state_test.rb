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
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      return runner.evals.values.map { |chunks| chunks.map { |chunk| chunk&.source } }
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
      "a method of the class that changes it" => { rules: "def clear = @singulars.clear" },
      "a push that may not run" => { rules: "def maybe(rule, replacement, flag) = (@singulars << [rule, replacement] if flag)" },
      "a core method the block hands an element to, redefined" => {
        body: "class ::String\n  def start_with?(*) = true\nend",
        reads: 'rules.singulars.each { |(rule, replacement)| "x".start_with?(replacement); break if result.sub!(rule, replacement) }'
      }
    }.each do |label, change|
      ruby = change[:reads] ? source(body: change[:body], reads: change[:reads]) : source(body: change[:body] || "")
      ruby = ruby.sub("    def singular(", "    #{change[:rules]}\n\n    def singular(") if change[:rules]
      assert_equal [[nil], [nil]], chunks(ruby), label
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
end
