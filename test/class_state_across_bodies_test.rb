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

  def chunks(ruby, kind: "class", signatures: rbs(kind))
    in_tmpdir do
      write("sig/app.rbs", signatures)
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

  CONFIG_RBS = <<~RBS
    class Config
      attr_reader name: Symbol
      def initialize: (Symbol) -> void
    end

    class Inflector
      self.@config: Config?
      def self.reset!: () -> Config
      def self.suffix: () -> Symbol
    end

    class Model
      def self.has_many_like: (Symbol name) -> untyped
    end
  RBS

  def config_inflector(after: "", writer: "def self.reset! = (@config = Config.new(:article))")
    <<~RUBY
      class Config
        attr_reader :name

        def initialize(name)
          @name = name
        end
      end

      class Inflector
        @config = Config.new(:post)

        #{writer}
        def self.suffix = @config.name

        #{after}
      end
    RUBY
  end

  def config_model(body: "")
    <<~RUBY
      class Model
        def self.has_many_like(name)
          class_eval "def \#{Inflector.suffix}_ids; []; end"
        end

        #{body}
      end
    RUBY
  end

  def test_a_class_ivar_a_class_method_rewrites_in_a_later_body_does_not_fold
    ruby = config_inflector + config_model(body: "Inflector.reset!\n  has_many_like :posts")
    assert_equal [nil], chunks(ruby, signatures: CONFIG_RBS)
  end

  def test_a_class_ivar_a_class_method_rewrites_in_its_own_body_does_not_fold
    ruby = config_model + config_inflector(after: "reset!\n  Model.has_many_like(:posts)")
    assert_equal [nil], chunks(ruby, signatures: CONFIG_RBS)
  end

  SAME_BODY_MACRO = 'def self.has_many_like(name) = class_eval "def #{suffix}_ids; []; end"'

  def test_a_class_ivar_a_class_method_rewrites_in_the_same_body_does_not_fold
    ruby = config_inflector(after: "#{SAME_BODY_MACRO}\n  reset!\n  has_many_like :posts")
    assert_equal [nil], chunks(ruby, signatures: CONFIG_RBS.sub("def self.suffix", "def self.has_many_like: (Symbol name) -> untyped\n  def self.suffix"))
  end

  def test_a_class_ivar_read_directly_after_a_call_that_may_rewrite_it_does_not_fold
    stamp = 'def self.stamp(name) = class_eval "def #{name}_ids; []; end"'
    ruby = config_inflector(after: "#{stamp}\n  reset!\n  stamp(@config.name)")
    assert_equal [nil], chunks(ruby, signatures: CONFIG_RBS.sub("def self.suffix", "def self.stamp: (Symbol name) -> untyped\n  def self.suffix"))
  end

  def test_a_class_ivar_no_method_rewrites_folds_in_the_same_body
    ruby = config_inflector(writer: "", after: "#{SAME_BODY_MACRO}\n  has_many_like :posts")
    signatures = CONFIG_RBS.sub("def self.reset!: () -> Config", "def self.has_many_like: (Symbol name) -> untyped")
    assert_equal ["def post_ids; []; end"], chunks(ruby, signatures: signatures)
  end

  def test_a_class_ivar_no_method_rewrites_folds_in_a_later_body
    ruby = config_inflector(writer: "") + config_model(body: "has_many_like :posts")
    assert_equal ["def post_ids; []; end"], chunks(ruby, signatures: CONFIG_RBS.sub("def self.reset!: () -> Config\n", ""))
  end

  ASSOCIATIONS_RBS = <<~RBS
    module Core
      module ClassMethods
        @generated_association_methods: Module?
        def generated_association_methods: () -> Module
      end
    end

    class Builder
      def self.build: (untyped model, Symbol name) -> untyped
      def self.define_accessors: (untyped model, Symbol name) -> untyped
      def self.define_readers: (untyped mixin, Symbol name) -> untyped
      def self.touch: (untyped model) -> untyped
    end

    class Base
      extend Core::ClassMethods
      def self.has_many: (Symbol name) -> untyped
    end

    class Post < Base
    end

    module Post::GeneratedAssociationMethods
    end
  RBS

  def associations(touch)
    <<~RUBY
      module Core
        module ClassMethods
          def generated_association_methods
            @generated_association_methods ||= begin
              mod = const_set(:GeneratedAssociationMethods, Module.new)
              include mod
              mod
            end
          end
        end
      end

      class Builder
        def self.build(model, name)
          touch(model)
          define_accessors(model, name)
        end

        def self.touch(model) = #{touch}

        def self.define_accessors(model, name)
          mixin = model.generated_association_methods
          define_readers(mixin, name)
        end

        def self.define_readers(mixin, name) = mixin.class_eval "def \#{name}; 1; end"
      end

      class Base
        def self.has_many(name) = Builder.build(self, name)
      end

      class Post < Base
        has_many :comments
      end
    RUBY
  end

  def test_a_nil_memo_outlives_a_call_with_no_body_in_the_program
    assert_equal(
      ["module GeneratedAssociationMethods\nend", "include ::Post::GeneratedAssociationMethods", "def comments; 1; end"],
      chunks(associations("model.name"), signatures: ASSOCIATIONS_RBS)
    )
  end

  def test_a_nil_memo_does_not_outlive_a_call_that_writes_the_ivar
    assert_equal(
      [nil, nil, "def comments; 1; end"],
      chunks(associations("model.instance_variable_set(:@generated_association_methods, Post::GeneratedAssociationMethods)"), signatures: ASSOCIATIONS_RBS)
    )
  end
end
