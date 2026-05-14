require_relative "test_helper"

class ContractsRunnerTest < Minitest::Test
  include TestHelper
  include ShellHelper

  Contracts = Steep::Contracts
  Project = Steep::Project

  def dirs
    @dirs ||= []
  end

  def envs
    @envs ||= []
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

  FIXTURE_RBS = <<~RBS
    class Foo
      attr_reader name: String?
      def helper: () -> Integer
    end
  RBS

  TRIGGERING_RUBY = <<~RUBY
    class Foo
      def helper
        name.size
      end
    end
  RUBY

  SAFE_RUBY = <<~RUBY
    class Foo
      def helper
        1 + 2
      end
    end
  RUBY

  def test_runner_infers_and_returns_contract
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", TRIGGERING_RUBY)
      project = setup_project(steepfile: FIXTURE_STEEPFILE)

      contracts = Contracts::Runner.run(project)

      assert_equal 1, contracts.size
      assert_equal "Foo", contracts.first.type_name
      assert_equal :helper, contracts.first.method_name
      assert_equal :name, contracts.first.requires.first.expr.method
    end
  end

  def test_runner_write_creates_sidecar_with_inferred_content
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", TRIGGERING_RUBY)
      project = setup_project(steepfile: FIXTURE_STEEPFILE)

      runner = Contracts::Runner.new(project)
      contracts = runner.run
      runner.write(contracts)

      sidecar = current_dir + Contracts::DEFAULT_SIDECAR_PATH
      assert sidecar.file?, "expected sidecar at #{sidecar}"

      reparsed = Contracts::Store.from_hash(YAML.safe_load(sidecar.read), source: sidecar.to_s)
      contract = reparsed.lookup_instance("Foo", :helper)
      refute_nil contract
      assert_equal :name, contract.requires.first.expr.method
    end
  end

  def test_runner_write_removes_sidecar_when_no_contracts
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", SAFE_RUBY)
      project = setup_project(steepfile: FIXTURE_STEEPFILE)

      sidecar = current_dir + Contracts::DEFAULT_SIDECAR_PATH
      sidecar.parent.mkpath
      sidecar.write("stale\n")

      runner = Contracts::Runner.new(project)
      contracts = runner.run
      runner.write(contracts)

      assert_empty contracts
      refute sidecar.file?, "expected stale sidecar to be removed when no contracts are inferred"
    end
  end

  def test_runner_is_idempotent
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", TRIGGERING_RUBY)
      project = setup_project(steepfile: FIXTURE_STEEPFILE)

      runner = Contracts::Runner.new(project)
      first = runner.run
      runner.write(first)
      first_bytes = (current_dir + Contracts::DEFAULT_SIDECAR_PATH).read

      second = Contracts::Runner.run(project)
      runner.write(second)
      second_bytes = (current_dir + Contracts::DEFAULT_SIDECAR_PATH).read

      assert_equal first_bytes, second_bytes, "expected idempotent sidecar across two runs"
    end
  end

  def test_runner_uses_existing_sidecar_for_subsequent_runs
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", TRIGGERING_RUBY)
      project = setup_project(steepfile: FIXTURE_STEEPFILE)

      runner = Contracts::Runner.new(project)
      contracts = runner.run
      runner.write(contracts)
      assert_equal 1, contracts.size

      project2 = setup_project(steepfile: FIXTURE_STEEPFILE)
      assert_equal 1, project2.contracts.methods.size,
                   "expected Project#contracts to load the freshly-written sidecar"
    end
  end
end
