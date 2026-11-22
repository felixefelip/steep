require_relative "test_helper"

class CallSiteSelvesTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  def dirs = (@dirs ||= [])

  RBS = <<~RBS
    class Base
      def self.register: (Symbol name) -> Entry
    end
    class Post < Base
    end
    class Entry
      def initialize: (Symbol name, singleton(Post) owner) -> void
    end
  RBS

  def ruby(register_body = "Entry.new(name, self)", calls: "register :comments")
    <<~RUBY
      class Base
        def self.register(name)
          #{register_body}
        end
      end

      class Post < Base
        #{calls}
      end

      class Entry
        def initialize(name, owner)
        end
      end
    RUBY
  end

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
  end

  def selves(rbs, ruby)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      steepfile = "target :app do\n  signature \"sig\"\n  check \"app\"\nend\n"
      write("Steepfile", steepfile)
      project = Steep::Project.new(steepfile_path: current_dir + "Steepfile")
      Steep::Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
      runner = Steep::Specializations::Runner.new(project)
      runner.run
      return runner.selves
    end
  end

  def checked(ruby, selves)
    with_checker(RBS, with_stdlib: true) do |checker|
      source = parse_ruby(ruby)
      store = Steep::Specializations::Store.from_hash({ "selves" => selves }, source: nil, base_dir: Pathname("/"), bodies: {})
      with_standard_construction(checker, source, specializations: store) do |construction, typing|
        construction.synthesize(source.node)
        yield typing
      end
    end
  end

  def test_a_method_every_call_of_which_runs_it_on_a_subclass_records_that_self
    assert_equal({ "Base.register" => ["singleton(::Post)"] }, selves(RBS, ruby))
  end

  def test_a_method_called_on_its_own_class_records_no_self
    assert_equal({}, selves(RBS, ruby(calls: "") + "Base.register(:comments)\n"))
  end

  def test_a_call_on_the_class_itself_is_among_the_selves
    assert_equal({ "Base.register" => ["singleton(::Base)", "singleton(::Post)"] }, selves(RBS, ruby + "Base.register(:posts)\n"))
  end

  def test_a_body_one_of_whose_calls_runs_it_on_its_own_class_keeps_its_generic_check
    checked(ruby, { "Base.register" => ["singleton(::Base)", "singleton(::Post)"] }) do |typing|
      assert_typing_error(typing, size: 1) do |errors|
        assert_any!(errors) { |error| assert_instance_of Steep::Diagnostic::Ruby::ArgumentTypeMismatch, error }
      end
    end
  end

  def test_the_generic_check_reports_handing_on_a_self_no_call_runs_it_on
    checked(ruby, {}) do |typing|
      assert_typing_error(typing, size: 1) do |errors|
        assert_any!(errors) { |error| assert_instance_of Steep::Diagnostic::Ruby::ArgumentTypeMismatch, error }
      end
    end
  end

  def test_a_body_is_checked_on_the_selves_its_calls_run_it_on
    checked(ruby, { "Base.register" => ["singleton(::Post)"] }) do |typing|
      assert_no_error typing
    end
  end

  def test_an_error_on_a_self_its_calls_run_it_on_is_still_reported
    checked(ruby("Entry.new(name.unknown, self)"), { "Base.register" => ["singleton(::Post)"] }) do |typing|
      assert_typing_error(typing, size: 1) do |errors|
        assert_any!(errors) { |error| assert_instance_of Steep::Diagnostic::Ruby::NoMethod, error }
      end
    end
  end

  def test_a_body_checked_on_its_selves_reports_nothing_its_generic_check_does_not
    rbs = RBS.sub("def self.register: (Symbol name) -> Entry", "def self.register: (Symbol name) -> Entry\n  def self.make: () -> untyped")
    with_checker(rbs + "class Post\n  def self.make: (Integer) -> untyped\nend\n", with_stdlib: true) do |checker|
      source = parse_ruby(ruby("make(name)"))
      store = Steep::Specializations::Store.from_hash({ "selves" => { "Base.register" => ["singleton(::Post)"] } }, source: nil, base_dir: Pathname("/"), bodies: {})
      with_standard_construction(checker, source, specializations: store) do |construction, typing|
        construction.synthesize(source.node)
        assert_empty typing.errors.grep(Steep::Diagnostic::Ruby::ArgumentTypeMismatch)
      end
    end
  end

  def test_an_initialize_records_no_self
    assert_equal({}, selves(RBS.sub("def initialize: (Symbol name, singleton(Post) owner) -> void", "def initialize: (Symbol name, untyped owner) -> void"), ruby("Entry.new(:c, self)") + "Entry.new(:d, 1)\n").reject { |key, _| key.start_with?("Base.") })
  end

  def test_a_body_keeps_the_types_of_its_generic_check
    checked(ruby, { "Base.register" => ["singleton(::Post)"] }) do |typing|
      self_node = typing.source.node.children[0].children[2].children[3].children[3]
      assert_equal parse_type("self"), typing.type_of(node: self_node)
    end
  end
end
