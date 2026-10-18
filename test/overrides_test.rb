require_relative "test_helper"

class OverridesTest < Minitest::Test
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

  def setup_project
    steepfile = "target :app do\n  signature \"sig\"\n  check \"app\"\nend\n"
    write("Steepfile", steepfile)
    project = Steep::Project.new(steepfile_path: current_dir + "Steepfile")
    Steep::Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
    project
  end

  def run_specializations(rbs, ruby)
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby)
      return Steep::Specializations::Runner.run(setup_project)
    end
  end

  BASE_RUBY = <<~'RUBY'
    class Base
      def self.tag(name) = "#{name}!"
    end
    class Child < Base
      def self.tag(name) = "#{name}?"
    end
  RUBY

  def test_a_call_on_a_class_overriding_the_method_without_a_signature_is_not_specialized_with_the_parents_body
    rbs = "class Base\n  def self.tag: (Symbol name) -> String\n  def self.use: () -> untyped\nend\nclass Child < Base\nend\n"
    ruby = BASE_RUBY.sub("class Child", "class Base\n  def self.use = Child.tag(:a)\nend\nclass Child")

    assert_equal({}, run_specializations(rbs, ruby))
  end

  def test_a_call_on_the_class_whose_body_it_runs_is_still_specialized
    rbs = "class Base\n  def self.tag: (Symbol name) -> String\n  def self.use: () -> untyped\nend\nclass Child < Base\nend\n"
    ruby = BASE_RUBY.sub("class Child", "class Base\n  def self.use = Base.tag(:a)\nend\nclass Child")

    assert_equal({ "Base.tag" => { "(:a)" => '"a!"' } }, run_specializations(rbs, ruby))
  end

  CHECKED_RBS = <<~RBS
    class Base
      def self.tag: (Symbol name) -> String
    end
    class Child < Base
      def self.tag: (Symbol name) -> String
    end
    class User
      def self.any: (singleton(Base) klass) -> String
      def self.exact: () -> String
    end
  RBS

  CHECKED_RUBY = <<~'RUBY'
    class User
      def self.any(klass) = klass.tag(:a)
      def self.exact = Base.tag(:a)
    end
  RUBY

  def check_calls
    with_checker(CHECKED_RBS, with_stdlib: true) do |checker|
      source = parse_ruby(CHECKED_RUBY)
      store = Steep::Specializations::Store.from_hash({ "methods" => { "Base.tag" => { "(:a)" => '"a!"' } } }, source: nil, base_dir: Pathname("/"))
      with_standard_construction(checker, source, specializations: store) do |construction, typing|
        construction.synthesize(source.node)
        any, exact = source.node.children[2].children.map { |def_node| def_node.children[3] }
        yield typing.type_of(node: any), typing.type_of(node: exact)
      end
    end
  end

  def test_a_receiver_that_may_be_a_subclass_overriding_the_method_is_not_specialized
    check_calls do |any, _|
      assert_equal parse_type("::String"), any
    end
  end

  def test_a_receiver_named_by_its_constant_is_specialized
    check_calls do |_, exact|
      assert_equal parse_type('"a!"'), exact
    end
  end
end
