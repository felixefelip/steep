require_relative "test_helper"

# Tests for the project-wide constructor reader→parameter index consumed by
# `TypeConstruction` at `.new` call sites (felixefelip/steep#60). Covers
# building from source, lookups, and invalidation.
class ProjectConstructorBindingRegistryTest < Minitest::Test
  include TestHelper
  include ShellHelper

  Project = Steep::Project
  ConstructorBindingRegistry = Steep::Project::ConstructorBindingRegistry

  def dirs
    @dirs ||= []
  end

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
    path
  end

  def setup_project(steepfile:)
    write("Steepfile", steepfile)
    project = Project.new(steepfile_path: current_dir + "Steepfile")
    Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
    project
  end

  FIXTURE_STEEPFILE = <<~STEEPFILE
    target :app do
      signature "sig"
      check "app"
    end
  STEEPFILE

  def test_builds_and_looks_up_bindings_from_sources
    in_tmpdir do
      write("app/proxy.rb", <<~RUBY)
        class Proxy
          def initialize(klass, owner)
            @owner = owner
          end
          def owner = @owner
        end
      RUBY
      project = setup_project(steepfile: FIXTURE_STEEPFILE)
      registry = ConstructorBindingRegistry.build(project)

      assert_equal({ owner: 1 }, registry.bindings_for("Proxy"))
      assert_equal({ owner: 1 }, registry.bindings_for("::Proxy"), "leading `::` is stripped")
      assert_nil registry.bindings_for("Nope")
    end
  end

  def test_a_body_ingested_after_a_lookup_is_found_by_the_next_one
    registry = ConstructorBindingRegistry.new
    assert_empty registry.method_bodies("Late")
    assert_empty registry.singleton_method_bodies("Late")

    registry.ingest_source("class Late\n  def first = 1\nend\n", path_name: "first.rb")
    assert_equal [:first], registry.method_bodies("Late").keys
    assert_equal [:first], registry.method_bodies(RBS::TypeName.parse("::Late")).keys

    registry.ingest_source("class Late\n  def second = 2\n  def self.made = new\nend\n", path_name: "second.rb")
    assert_equal [:first, :second], registry.method_bodies("Late").keys
    assert_equal [:first, :second], registry.method_bodies(RBS::TypeName.parse("::Late")).keys
    assert_equal [:made], registry.singleton_method_bodies("Late").keys
  end

  def test_a_parameter_a_value_is_handed_to_is_followed_once_however_many_paths_reach_it
    hands = (1..8).map { |n| "  def self.m#{n}(x) = (m#{n + 1}(x); m#{n + 1}(x))\n" }.join
    source = "class Holder\n  def self.rules = @rules ||= {}\n  def self.go = m1(rules)\n#{hands}  def self.m9(x) = x.size\nend\n"
    followed = Hash.new(0)
    counting = Module.new do
      define_method(:parameter_uses) { |def_node, index| super(def_node, index).tap { followed[def_node.children[1]] += 1 } }
    end
    Steep::TypeInference::ClassMemoAnalyzer.singleton_class.prepend(counting)

    registry = ConstructorBindingRegistry.new
    registry.ingest_source(source, path_name: "app.rb")
    registry.uses_of(:rules)

    assert_equal 1, followed[:m9]
  end

  def test_a_call_on_an_ivar_of_a_class_object_is_on_a_plain_hash_only_where_its_class_sets_one
    {
      "@memo = {}" => true,
      "def self.reset = @memo = {}" => true,
      "@memo = Store.new" => false,
      "@memo = {}\n  def self.reset = @memo = Store.new" => false,
      "@memo = {}\n  def write = @memo = Store.new" => true,
      "" => false
    }.each do |assigned, literal|
      registry = ConstructorBindingRegistry.new
      registry.ingest_source("class Store\n  def put(key) = @key = key\nend\nclass Use\n  #{assigned}\n  def self.read = @memo.put(:a)\nend\n", path_name: "app.rb")
      call = registry.calls_of(:put).find { |each| each.singleton }

      assert_equal literal, registry.literal_receiver?(call), assigned
    end
  end

  def class_bodies_of(source, name)
    registry = ConstructorBindingRegistry.new
    registry.ingest_source(source, path_name: "app.rb")
    registry.class_bodies(name)
  end

  def test_a_body_that_declares_a_module_or_mixes_in_an_inert_one_runs_no_code
    source = <<~RUBY
      module Helpers
        def help = 1
      end

      class Widget
        def self.m = 1
      end

      class Widget
        module Generated
        end
        include Helpers
      end
    RUBY

    assert_equal 0, class_bodies_of(source, "Widget")
  end

  def test_a_body_mixing_in_a_module_with_a_hook_or_one_it_does_not_have_runs_code
    hooked = <<~RUBY
      module Hooked
        def self.included(base) = nil
      end

      class Widget
        include Hooked
      end
    RUBY

    assert_equal 1, class_bodies_of(hooked, "Widget")
    assert_equal 1, class_bodies_of("class Widget\n  include Elsewhere\nend\n", "Widget")
  end

  def test_a_nested_module_whose_body_runs_code_runs_it_in_the_outer_body
    assert_equal 1, class_bodies_of("class Widget\n  module Helpers\n    Widget.registry\n  end\nend\n", "Widget")
  end

  def test_rebuilt_after_invalidation
    in_tmpdir do
      write("app/proxy.rb", <<~RUBY)
        class Proxy
          def initialize(owner)
            @owner = owner
          end
          def owner = @owner
        end
      RUBY
      project = setup_project(steepfile: FIXTURE_STEEPFILE)
      assert_equal 0, project.constructor_binding_registry.bindings_for("Proxy")&.dig(:owner)

      write("app/proxy.rb", <<~RUBY)
        class Proxy
          def initialize(klass, owner)
            @owner = owner
          end
          def owner = @owner
        end
      RUBY
      project.invalidate_constructor_binding_registry!
      assert_equal 1, project.constructor_binding_registry.bindings_for("Proxy")&.dig(:owner),
                   "the index reflects the new constructor arity after invalidation"
    end
  end
end
