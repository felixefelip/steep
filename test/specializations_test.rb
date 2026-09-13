require_relative "test_helper"
require "timeout"

class SpecializationsTest < Minitest::Test
  include TestHelper
  include ShellHelper

  Specializations = Steep::Specializations
  Project = Steep::Project

  def dirs
    @dirs ||= []
  end

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
    path
  end

  def setup_project(steepfile: STEEPFILE)
    write("Steepfile", steepfile)
    project = Project.new(steepfile_path: current_dir + "Steepfile")
    Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
    project
  end

  STEEPFILE = <<~STEEPFILE
    target :app do
      signature "sig"
      check "app"
    end
  STEEPFILE

  FIXTURE_RBS = <<~RBS
    module Example
      class Foo
        def name: () -> "name"
        def action: () -> "delete"
        def call_name_action: () -> String
        def call_action: () -> String
        def call_unknown: (flag_name: untyped) -> String

        private

        def call: (?flag_name: bool) -> String
      end
    end
  RBS

  FIXTURE_RUBY = <<~RUBY
    module Example
      class Foo
        def name
          "name"
        end

        def action
          "delete"
        end

        def call_name_action
          call(flag_name: true)
        end

        def call_action
          call(flag_name: false)
        end

        def call_unknown(flag_name:)
          call(flag_name: flag_name)
        end

        private

        def call(flag_name: false)
          if flag_name
            "\#{name}_\#{action}"
          else
            action
          end
        end
      end
    end
  RUBY

  def test_runner_records_one_return_per_argument_tuple
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)

      methods = Specializations::Runner.run(setup_project)

      assert_equal(
        { "(flag_name: true)" => '"name_delete"', "(flag_name: false)" => '"delete"' },
        methods.fetch("Example::Foo#call")
      )
    end
  end

  def test_runner_records_nothing_for_a_call_that_fixes_no_literal
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)

      methods = Specializations::Runner.run(setup_project)

      refute_includes methods.keys, "Example::Foo#call_unknown"
    end
  end

  def test_runner_specializes_a_positional_argument
    in_tmpdir do
      write("sig/foo.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def label: (bool) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            label(true)
          end

          def label(loud)
            if loud
              "LOUD"
            else
              "quiet"
            end
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"LOUD"' }, methods.fetch("Bar#label"))
    end
  end

  # felixefelip/rbs_infer#345 stage S5. `relay` has no literal in its own body —
  # it hands its parameter on — so its return is only specializable once `label`
  # already is, which is a second generation.
  def test_runner_carries_a_literal_across_two_calls
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def relay: (bool) -> String
          def label: (bool) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            relay(true)
          end

          def relay(loud)
            label(loud)
          end

          def label(loud)
            if loud
              "LOUD"
            else
              "quiet"
            end
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"LOUD"' }, methods.fetch("Bar#label"))
      assert_equal({ "(true)" => '"LOUD"' }, methods.fetch("Bar#relay"))
    end
  end

  # A tuple whose argument is a literal only because the call inside it
  # specialized: `shout` passes `label(true)`, typed `String` until `label` has
  # its entry and `"LOUD"` after.
  def test_runner_grows_a_tuple_from_a_specialized_argument
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def shout: () -> String
          def wrap: (String) -> String
          def label: (bool) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def shout
            wrap(label(true))
          end

          def wrap(text)
            text
          end

          def label(loud)
            if loud
              "LOUD"
            else
              "quiet"
            end
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ '("LOUD")' => '"LOUD"' }, methods.fetch("Bar#wrap"))
    end
  end

  # The fixpoint's termination, which is the whole reason widening exists: every
  # generation folds a longer literal and supplies a tuple never seen before.
  def test_runner_terminates_on_a_body_that_folds_a_longer_literal
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def start: () -> String
          def g: (String) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def start
            g("a")
          end

          def g(s)
            g("\#{s}x")
          end
        end
      RUBY

      methods = Timeout.timeout(60) { Specializations::Runner.run(setup_project) }

      recorded = methods.fetch("Bar#g", {})
      assert_operator recorded.size, :<=, Specializations::Runner::WIDEN_AFTER
      recorded.each_key { |key| assert_operator key.length, :<=, Specializations::Runner::LITERAL_WIDTH }
    end
  end

  def test_runner_writes_and_deletes_the_sidecar
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)
      project = setup_project
      runner = Specializations::Runner.new(project)

      runner.write(runner.run)

      assert_predicate runner.output_path, :file?
      store = Specializations.load(project.base_dir)
      assert_equal(
        '"name_delete"',
        store.methods.fetch("Example::Foo#call").fetch("(flag_name: true)")
      )

      runner.write({})
      refute_predicate runner.output_path, :file?
    end
  end

  def test_store_ignores_a_sidecar_from_another_schema_version
    store = Specializations::Store.from_hash(
      { "version" => 99, "methods" => { "Foo#bar" => { "(1)" => "Integer" } } },
      source: "test"
    )

    assert_predicate store, :empty?
  end

  def test_a_call_site_reads_back_the_specialized_return_type
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)
      project = setup_project
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!

      types = body_types(project, current_dir + "app/foo.rb")

      assert_equal '"name_delete"', types.fetch("call_name_action")
      assert_equal '"delete"', types.fetch("call_action")
      assert_equal "::String", types.fetch("call_unknown")
    end
  end

  def test_a_call_site_reads_the_declaration_without_a_sidecar
    in_tmpdir do
      write("sig/foo.rbs", FIXTURE_RBS)
      write("app/foo.rb", FIXTURE_RUBY)

      types = body_types(setup_project, current_dir + "app/foo.rb")

      assert_equal "::String", types.fetch("call_name_action")
    end
  end

  private

  # `{ "method name" => type }` for every `def` in `path`, as an ordinary check
  # of the project sees them.
  def body_types(project, path)
    target = project.targets.first or raise
    loader = Project::Target.construct_env_loader(options: target.options, project: project)
    file_loader = Steep::Services::FileLoader.new(base_dir: project.base_dir)
    file_loader.each_path_in_patterns(target.signature_pattern) do |sig|
      absolute = project.absolute_path(sig)
      loader.add(path: absolute) if absolute.file?
    end

    status = Steep::Services::SignatureService.load_from(loader, implicitly_returns_nil: target.implicitly_returns_nil).status
    source = Steep::Source.parse(path.read, path: path, factory: status.subtyping.factory)
    typing = Steep::Services::TypeCheckService.type_check(
      source: source,
      subtyping: status.subtyping,
      constant_resolver: status.constant_resolver,
      cursor: nil,
      contracts: project.contracts,
      postconditions: project.postconditions,
      callbacks: project.callbacks,
      specializations: project.specializations,
      delegation_registry: project.delegation_registry,
      constructor_bindings: project.constructor_binding_registry,
      return_forwarding: project.return_forwarding_registry,
      return_alias: project.return_alias_registry
    )

    result = {}
    typing.each_typing do |node, _|
      next unless node.type == :def

      body = node.children[2] or next
      result[node.children[0].to_s] = typing.type_of(node: body).to_s
    end
    result
  end
end
