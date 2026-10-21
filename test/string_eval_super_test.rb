require_relative "test_helper"

class StringEvalSuperTest < Minitest::Test
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

  RBS = <<~RBS
    class Writer
      def self.generate: (untyped owner, Symbol name) -> void
    end

    class IdsWriter < Writer
      def self.generate: (untyped owner, Symbol name) -> void
    end

    class Base
      def self.has_many: (Symbol name) -> untyped
    end

    class Post < Base
    end
  RBS

  def has_many_chunks(super_call)
    in_tmpdir do
      write("sig/base.rbs", RBS)
      write("app/base.rb", <<~RUBY)
        class Writer
          def self.generate(owner, name)
            owner.module_eval "def \#{name}; end"
          end
        end

        class IdsWriter < Writer
          def self.generate(owner, name)
            #{super_call}
            owner.module_eval "def \#{name}_ids; end"
          end
        end

        class Base
          def self.has_many(name) = IdsWriter.generate(self, name)
        end

        class Post < Base
          has_many :comments
        end
      RUBY

      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.evals.fetch("app/base.rb:#{19 + super_call.count("\n")}:2").map { |chunk| chunk&.source }
    end
  end

  def test_a_super_into_a_writer_is_read
    assert_equal ["def comments; end", "def comments_ids; end"], has_many_chunks("super(owner, name)")
  end

  def test_a_bare_super_into_a_writer_passes_the_method_s_parameters
    assert_equal ["def comments; end", "def comments_ids; end"], has_many_chunks("super")
  end

  def test_a_bare_super_passes_a_reassigned_parameter_not_the_argument
    assert_equal [nil, nil], has_many_chunks("name = :posts\n    super")
  end
end
