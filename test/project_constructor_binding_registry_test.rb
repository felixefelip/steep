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
