require_relative "test_helper"
require_relative "specializations_project_helper"

class CorrelatedPathsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  SIGNATURES = <<~RBS
    module Foo
      def bazinga: (singleton(Baz) | singleton(BazOther) module_included) -> void
    end
    module Baz
      def self.bazingado: (untyped base) -> void
    end
    module BazOther
      def self.bazingado: (untyped base) -> void
    end
    class Bar
    end
    class BarOther
    end
  RBS

  PATHS = <<~YAML
    app/foo.rb:
      modules:
      - anchor: Foo
        annotations: []
        paths:
          bazinga:
          - when:
              module_included: singleton(Baz)
            self: singleton(Bar)
          - when:
              module_included: singleton(BazOther)
            self: singleton(BarOther)
  YAML

  def with_module_convention
    previous = ENV["STEEP_MODULE_CONVENTION"]
    ENV["STEEP_MODULE_CONVENTION"] = "1"
    Steep::Source::ModuleSelfTypes.reset!
    Dir.chdir(current_dir) { yield }
  ensure
    ENV["STEEP_MODULE_CONVENTION"] = previous
    Steep::Source::ModuleSelfTypes.reset!
  end

  def test_the_call_runs_on_the_self_of_every_branch
    in_tmpdir do
      with_module_convention do
        project = setup_project
        write("sig/foo.rbs", SIGNATURES)
        write("sig/generated/.steep_module_self_types.yml", PATHS)
        path = write("app/foo.rb", <<~RUBY)
          module Foo
            def bazinga(module_included)
              module_included.bazingado(self)
            end
          end
        RUBY

        typing = checked(project, path)
        call = typing.each_typing.map(&:first).find { |node| node.type == :send }

        assert_empty typing.errors
        assert_equal "(singleton(Bar) | singleton(BarOther))", typing.self_type_of_call(node: call).to_s
      end
    end
  end
end
