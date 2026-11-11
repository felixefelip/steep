require_relative "test_helper"

class StringEvalExactModuleTest < Minitest::Test
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

  def test_a_memo_keeps_its_module_when_a_subclass_of_module_defines_a_method
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Base
          @generated_methods: Module?
          def self.generated_methods: () -> Module
          def self.has_reader: (Symbol name) -> untyped
        end

        class Post < Base
        end

        module Post::GeneratedMethods
        end

        class Class
          def unrelated: () -> nil
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Base
          def self.generated_methods
            @generated_methods ||= begin
              mod = const_set(:GeneratedMethods, Module.new)
              include mod
              mod
            end
          end

          def self.has_reader(name)
            generated_methods.class_eval "def \#{name}; 1; end"
          end
        end

        class Post < Base
          has_reader :comments
        end

        class Class
          def unrelated = nil
        end
      RUBY

      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      chunks = runner.evals.fetch("app/base.rb:16:2").map { |chunk| chunk && [chunk.source, chunk.target] }

      assert_equal(
        [
          ["module GeneratedMethods\nend", nil],
          ["include ::Post::GeneratedMethods", nil],
          ["def comments; 1; end", "::Post::GeneratedMethods"]
        ],
        chunks
      )
    end
  end
end
