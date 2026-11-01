require_relative "test_helper"

class CallSiteUnionsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  def dirs = (@dirs ||= [])

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
  end

  def declarations(rbs, ruby)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      return runner.declarations
    end
  end

  def setup_project
    steepfile = "target :app do\n  signature \"sig\"\n  check \"app\"\nend\n"
    write("Steepfile", steepfile)
    project = Steep::Project.new(steepfile_path: current_dir + "Steepfile")
    Steep::Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
    project
  end

  RULES_RBS = <<~RBS
    class Rules
      attr_reader singulars: Array[untyped]
      def initialize: () -> void
      def singular: (Regexp rule, ("" | "y") replacement) -> Array[untyped]
    end
    module Inflector
      self.@rules: Rules?
      def self.rules: () -> Rules
      def self.singularize: (("posts" | "categories") word) -> String
    end
    class Post
      def self.has_many_like: ((:posts | :categories) name) -> untyped
      def self.forward: (Symbol name) -> untyped
    end
  RBS

  def rules_ruby(post_body = "")
    <<~'RUBY' + <<~RUBY
      class Rules
        attr_reader :singulars
        def initialize
          @singulars = []
        end
        def singular(rule, replacement)
          @singulars.prepend([rule, replacement])
        end
      end
      module Inflector
        def self.rules
          @rules ||= Rules.new
        end
        rules.singular(/s\z/, "")
        rules.singular(/ies\z/, "y")
        def self.singularize(word)
          result = word.dup
          rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
          result
        end
      end
    RUBY
      class Post
        def self.has_many_like(name)
          class_eval "def \#{Inflector.singularize(name.to_s)}_ids; []; end"
        end
        has_many_like :posts
        has_many_like :categories
        #{post_body}
      end
    RUBY
  end

  def test_a_method_every_call_of_which_specialized_returns_what_they_returned
    assert_equal(
      {
        "Post.has_many_like" => "(:post_ids | :category_ids)",
        "Inflector.singularize" => '("post" | "category")',
        "Rules#singular" => '([[::Regexp, ""]] | [[::Regexp, "y"], [::Regexp, ""]])'
      },
      declarations(RULES_RBS, rules_ruby)
    )
  end

  def test_a_call_fixing_no_value_leaves_the_method_to_its_declaration
    ruby = rules_ruby("def self.forward(name) = has_many_like(name)")

    refute_includes declarations(RULES_RBS, ruby).keys, "Post.has_many_like"
  end

  def test_a_call_passing_a_union_of_literals_returns_what_one_of_them_returned
    rbs = <<~RBS
      class Tags
        def self.tag: (Symbol name) -> String
        def self.both: ((:a | :b) name) -> String
      end
    RBS
    ruby = <<~'RUBY'
      class Tags
        def self.tag(name) = "#{name}!"
        def self.both(name) = tag(name)
        tag(:a)
        both(:a)
        both(:b)
      end
    RUBY

    assert_equal({ "Tags.tag" => '("a!" | "b!")', "Tags.both" => '("a!" | "b!")' }, declarations(rbs, ruby))
  end

  WRITER_RBS = <<~RBS
    module Writer
      def self.generate: (singleton(Peel) owner, (:human_name | :nick) method) -> untyped
    end
    class Peel
      def self.human_name: (String index) -> String
      def self.banana_delegate: ((:human_name | :nick) method) -> untyped
    end
    class Rind < Peel
      def self.nick: (String name) -> String
    end
  RBS

  WRITER_RUBY = <<~'RUBY'
    module Writer
      def self.generate(owner, method)
        argument = owner.singleton_class.public_instance_method(method).parameters[0][1]
        owner.class_eval ["def #{method}(#{argument})", "  self.class.#{method}(#{argument})", "end"].join(";")
      end
    end
    class Peel
      def self.human_name(index) = index.upcase
      def self.banana_delegate(method) = Writer.generate(self, method)
      banana_delegate :human_name
    end
    class Rind < Peel
      def self.nick(name) = name
      banana_delegate :nick
    end
  RUBY

  def test_a_call_inside_a_body_is_read_under_each_call_of_that_body
    declarations = declarations(WRITER_RBS, WRITER_RUBY)

    assert_equal "(:human_name | :nick)", declarations["Writer.generate"]
    assert_equal "(:human_name | :nick)", declarations["Peel.banana_delegate"]
  end

  def test_a_call_inside_a_method_nothing_calls_is_read_under_its_declaration
    ruby = WRITER_RUBY.sub("  banana_delegate :human_name\n", "  def self.later = Writer.generate(self, :human_name)\n  banana_delegate :human_name\n")
    rbs = WRITER_RBS.sub("  def self.banana_delegate", "  def self.later: () -> untyped\n  def self.banana_delegate")

    refute_includes declarations(rbs, ruby).keys, "Writer.generate"
  end

  BODY_RBS = <<~RBS
    class Tags
      def self.tag: ((:a | :b) name) -> %s
    end
  RBS

  BODY_RUBY = <<~'RUBY'
    class Tags
      def self.tag(name)
        return "a!" if name == :a
        name.to_s
      end
    end
  RUBY

  def check_body(return_type, &block)
    with_checker(format(BODY_RBS, return_type), with_stdlib: true) do |checker|
      source = parse_ruby(BODY_RUBY)
      store = Steep::Specializations::Store.from_hash({ "declarations" => { "Tags.tag" => '("a!" | "b!")' } }, source: nil, base_dir: Pathname("/"), bodies: {})
      with_standard_construction(checker, source, specializations: store) do |construction, typing|
        construction.synthesize(source.node)
        yield typing, source.node.children[2].children[3]
      end
    end
  end

  def test_a_body_checked_under_its_declaration_answers_what_its_calls_returned
    check_body('("a!" | "b!")') do |typing, body|
      assert_no_error typing
      assert_equal parse_type('"a!" | "b!"'), typing.type_of(node: body)
    end
  end

  def test_what_the_calls_returned_still_has_to_fit_the_declaration
    check_body('"a!"') do |typing, _|
      assert_typing_error(typing, size: 1) do |errors|
        assert_any!(errors) do |error|
          assert_instance_of Steep::Diagnostic::Ruby::MethodBodyTypeMismatch, error
          assert_equal parse_type('"a!" | "b!"'), error.actual
        end
      end
    end
  end

  def test_a_body_checked_for_one_call_is_not_answered_by_all_of_them
    with_checker(format(BODY_RBS, "String"), with_stdlib: true) do |checker|
      source = parse_ruby(BODY_RUBY)
      def_node = source.node.children[2]
      arguments = Steep::Specializations::Arguments.new(positionals: [parse_type(":a")], keywords: {}, self_ivars: {}, class_states: {})
      store = Steep::Specializations::Store
        .from_hash({ "declarations" => { "Tags.tag" => '("a!" | "b!")' } }, source: nil, base_dir: Pathname("/"), bodies: {})
        .with_active({ [source.path.to_s, def_node.loc.expression.begin_pos] => arguments })
      with_standard_construction(checker, source, specializations: store) do |construction, typing|
        construction.synthesize(source.node)
        refute_equal parse_type('"a!" | "b!"'), typing.type_of(node: def_node.children[3])
      end
    end
  end

  def test_an_override_with_no_signature_of_its_own_is_not_answered_by_its_parents_calls
    rbs = "class Base\n  def self.tag: (Symbol name) -> String\nend\nclass Child < Base\nend\n"
    ruby = "class Base\n  def self.tag(name) = \"\#{name}!\"\nend\nclass Child < Base\n  def self.tag(name) = 42\nend\n"

    with_checker(rbs, with_stdlib: true) do |checker|
      source = parse_ruby(ruby)
      store = Steep::Specializations::Store.from_hash({ "declarations" => { "Base.tag" => '("a!" | "b!")' } }, source: nil, base_dir: Pathname("/"), bodies: {})
      with_standard_construction(checker, source, specializations: store) do |construction, typing|
        construction.synthesize(source.node)

        assert_typing_error(typing, size: 1) do |errors|
          assert_any!(errors) do |error|
            assert_instance_of Steep::Diagnostic::Ruby::MethodBodyTypeMismatch, error
            assert_equal parse_type("::Integer"), error.actual
          end
        end
      end
    end
  end

  def test_a_call_passing_a_union_of_literals_is_typed_by_what_each_member_returned
    rbs = "class Tags\n  def self.tag: (Symbol name) -> String\n  def self.pick: () -> (:a | :b)\nend\n"
    entries = { "methods" => { "Tags.tag" => { "(:a)" => '"a!"', "(:b)" => '"b!"' } } }

    with_checker(rbs, with_stdlib: true) do |checker|
      source = parse_ruby("Tags.tag(Tags.pick)\n")
      store = Steep::Specializations::Store.from_hash(entries, source: nil, base_dir: Pathname("/"), bodies: {})
      with_standard_construction(checker, source, specializations: store) do |construction, typing|
        construction.synthesize(source.node)

        assert_equal parse_type('"a!" | "b!"'), typing.type_of(node: source.node)
      end
    end
  end

  def test_a_union_that_is_not_of_literals_is_looked_up_whole
    rbs = "class Tags\n  def self.tag: (untyped name) -> String\n  def self.pick: () -> (String | Integer)\nend\n"
    entries = { "methods" => { "Tags.tag" => { "((::String | ::Integer))" => '"either"' } } }

    with_checker(rbs, with_stdlib: true) do |checker|
      source = parse_ruby("Tags.tag(Tags.pick)\n")
      store = Steep::Specializations::Store.from_hash(entries, source: nil, base_dir: Pathname("/"), bodies: {})
      with_standard_construction(checker, source, specializations: store) do |construction, typing|
        construction.synthesize(source.node)

        assert_equal parse_type('"either"'), typing.type_of(node: source.node)
      end
    end
  end

  def test_the_sidecar_carries_the_declarations
    in_tmpdir do
      path = current_dir + "specializations.yml"
      Steep::Specializations::Writer.write(path, {}, { "Tags.tag" => '("a!" | "b!")' }, {}, {})
      store = Steep::Specializations.load(current_dir, path: "specializations.yml")

      with_checker do |checker|
        assert_equal parse_type('"a!" | "b!"'), store.declaration_type("Tags.tag", factory: checker.factory)
      end
    end
  end

  def built(assoc_body)
    declarations(<<~RBS, <<~RUBY)["Label.text"]
      class Label
        def self.text: (Symbol name) -> Symbol
      end
      class Macro
        def initialize: (Symbol name) -> void
      end
      class Assoc < Macro
        def initialize: (Symbol name) -> void
      end
    RBS
      class Label
        def self.text(name) = name
      end

      class Macro
        def initialize(name)
          @text = Label.text(name)
        end
      end

      class Assoc < Macro
        #{assoc_body}
      end

      Assoc.new(:comments)
    RUBY
  end

  def test_a_call_in_an_initialize_is_read_under_each_new_that_runs_it
    assert_equal ":comments", built("")&.to_s
  end

  def test_a_call_in_an_initialize_is_read_under_each_super_that_reaches_it
    assert_equal ":comments", built("def initialize(name)\n    super(name)\n  end")&.to_s
  end

  def test_a_call_in_an_initialize_is_read_under_each_bare_super_that_reaches_it
    assert_equal ":comments", built("def initialize(name)\n    super\n  end")&.to_s
  end
end
