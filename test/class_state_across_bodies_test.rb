require_relative "test_helper"

class ClassStateAcrossBodiesTest < Minitest::Test
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

  def chunks(ruby, kind: "class")
    in_tmpdir do
      write("sig/app.rbs", rbs(kind))
      write("app/app.rb", ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      return runner.evals.values.flat_map { |chunks| chunks.map { |chunk| chunk&.source } }
    end
  end

  def rbs(kind)
    <<~RBS
      class Rules
        attr_reader singulars: Array[untyped]
        def initialize: () -> Array[untyped]
        def singular: (untyped rule, untyped replacement) -> Array[untyped]
      end

      #{kind} Inflector
        self.@rules: Rules?
        def self.rules: () -> Rules
        def self.singularize: (String word) -> String
      end

      class Model
        def self.has_many_like: (Symbol name) -> untyped
      end
    RBS
  end

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

  def inflector(kind: "class", before: "", after: "")
    <<~RUBY
      #{kind} Inflector
        def self.rules
          @rules ||= Rules.new
        end

        #{before}
        rules.singular(/s\\z/, "")
        rules.singular(/ies\\z/, "y")

        def self.singularize(word)
          result = word.dup
          rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
          result
        end

        #{after}
      end
    RUBY
  end

  def model(body: "has_many_like :posts\n  has_many_like :categories")
    <<~RUBY
      class Model
        def self.has_many_like(name)
          class_eval "def \#{Inflector.singularize(name.to_s)}_ids; []; end"
        end

        #{body}
      end
    RUBY
  end

  FOLDED = ["def post_ids; []; end", "def category_ids; []; end"].freeze

  def test_a_later_class_body_reads_the_state_an_earlier_one_left
    assert_equal FOLDED, chunks(RULES + inflector + model)
  end

  def test_a_module_leaves_its_state_as_a_class_does
    assert_equal FOLDED, chunks(RULES + inflector(kind: "module") + model, kind: "module")
  end

  def test_a_body_that_runs_before_the_rules_are_written_does_not_fold
    assert_equal [nil, nil], chunks(RULES + model + inflector)
  end

  def test_a_caller_reached_before_the_rules_are_written_does_not_fold
    ruby = RULES + model(body: "") + inflector(before: "Model.has_many_like(:posts)")
    refute_includes chunks(ruby), "def post_ids; []; end"
  end

  def test_a_caller_reached_from_the_body_after_the_rules_are_written_folds
    ruby = RULES + model(body: "") + inflector(after: "Model.has_many_like(:posts)")
    assert_equal ["def post_ids; []; end"], chunks(ruby)
  end

  def test_a_later_body_that_changes_the_memo_object_does_not_fold
    ruby = RULES + inflector + model(body: "Inflector.rules.singular(/posts\\z/, \"article\")\n  has_many_like :posts")
    refute_includes chunks(ruby), "def post_ids; []; end"
  end

  def test_a_method_is_checked_under_its_call_site_not_its_definition
    ruby = RULES + model(body: "") + inflector + "Model.has_many_like(:posts)\n"
    assert_equal ["def post_ids; []; end"], chunks(ruby)
  end
end
