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

  # A rest parameter holds the arguments its call passed, in order and no more:
  # the call builds that array, so the body checked for that call reads it as
  # a tuple — the count of an `each` over it included. Anything that could
  # change it unseen (a mutating call, a second name) takes that away.
  def test_runner_reads_a_rest_parameter_as_the_arguments_passed
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def two: () -> String
          def one: () -> String
          def trailing: () -> String
          def after_optional: () -> String
          def nothing_left: () -> String
          def with_a_push: () -> String
          def through_join: () -> String
          def reversed: () -> String
          def aliased: () -> String
          def names: (*Symbol) -> String
          def pair: (Symbol, *Symbol, Symbol) -> String
          def opt: (Symbol, ?Symbol, *Symbol) -> String
          def tail: (Symbol, *Symbol) -> String
          def pushed: (*Symbol) -> String
          def joined: (*String) -> String
          def mutated: (*Symbol) -> String
          def leaked: (*Symbol) -> String
        end
      RBS
      write("app/bar.rb", <<~'RUBY')
        class Bar
          def two = names(:a, :b)
          def one = names(:a)
          def trailing = pair(:h, :m1, :m2, :t)
          def after_optional = opt(:a, :b, :c)
          def nothing_left = tail(:a)
          def with_a_push = pushed(:a)
          def through_join = joined("a", "b")
          def reversed = mutated(:a, :b)
          def aliased = leaked(:a)

          def names(*ms)
            parts = []
            ms.each { |m| parts << "def #{m}" }
            parts.join(";")
          end

          # The type of a method has no place for a positional after the rest,
          # so the count comes from the definition: `:t` is not one of `ms`.
          def pair(h, *ms, t)
            parts = []
            ms.each { |m| parts << "#{h}#{m}" }
            parts.join(";")
          end

          def opt(a, b = :d, *ms)
            parts = ["#{a}#{b}"]
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end

          def tail(a, *ms)
            parts = ["#{a}"]
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end

          def pushed(*ms)
            ms << :z
            parts = []
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end

          def joined(*ms)
            ms.join(",")
          end

          def mutated(*ms)
            ms.reverse!
            parts = []
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end

          def leaked(*ms)
            other = ms
            other << :q
            parts = []
            ms.each { |m| parts << "#{m}" }
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(:a, :b)" => '"def a;def b"', "(:a)" => '"def a"' }, methods.fetch("Bar#names"))
      assert_equal({ "(:h, :m1, :m2, :t)" => '"hm1;hm2"' }, methods.fetch("Bar#pair"))
      assert_equal({ "(:a, :b, :c)" => '"ab;c"' }, methods.fetch("Bar#opt"))
      assert_equal({ "(:a)" => '"a"' }, methods.fetch("Bar#tail"))
      assert_equal({ "(:a)" => '"a;z"' }, methods.fetch("Bar#pushed"))
      assert_equal({ '("a", "b")' => '"a,b"' }, methods.fetch("Bar#joined"))
      refute methods.key?("Bar#mutated")
      refute methods.key?("Bar#leaked")
    end
  end

  # A frame that hands its rest parameter on: the array it hands is the one the
  # call built, and nothing touched it before the hand-off, so the callee's
  # parameter arrives holding exactly that — and the call site is keyed on it.
  # Anything that could have changed it first, or a second name for it in the
  # same call, takes that away.
  def test_runner_follows_a_collection_handed_to_another_method
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def positional: () -> String
          def keyword: () -> String
          def mutated_first: () -> String
          def handed_twice: () -> String
          def outer: (*Symbol) -> String
          def outer_kw: (*Symbol) -> String
          def outer_mutates: (*Symbol) -> String
          def outer_twice: (*Symbol) -> String
          def gen: (untyped owner, Array[Symbol] methods) -> String
          def gen_kw: (methods: Array[Symbol]) -> String
          def gen_pair: (Array[Symbol] a, Array[Symbol] b) -> String
        end
      RBS
      write("app/bar.rb", <<~'RUBY')
        class Bar
          def positional = outer(:email)
          def keyword = outer_kw(:a, :b)
          def mutated_first = outer_mutates(:a, :b)
          def handed_twice = outer_twice(:a)

          def outer(*methods)
            gen(self, methods)
          end

          def outer_kw(*methods)
            gen_kw(methods: methods)
          end

          def outer_mutates(*methods)
            methods.reverse!
            gen(self, methods)
          end

          def outer_twice(*methods)
            gen_pair(methods, methods)
          end

          def gen(owner, methods)
            parts = []
            methods.each { |m| parts << "def #{m}" }
            parts.join(";")
          end

          def gen_kw(methods:)
            parts = []
            methods.each { |m| parts << "def #{m}" }
            parts.join(";")
          end

          def gen_pair(a, b)
            parts = []
            a.each { |m| parts << "def #{m}" }
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(:email)" => '"def email"' }, methods.fetch("Bar#outer"))
      assert_equal({ "(self, [:email])" => '"def email"' }, methods.fetch("Bar#gen"))
      assert_equal({ "(:a, :b)" => '"def a;def b"' }, methods.fetch("Bar#outer_kw"))
      assert_equal({ "(methods: [:a, :b])" => '"def a;def b"' }, methods.fetch("Bar#gen_kw"))
      refute methods.key?("Bar#outer_mutates")
      refute methods.key?("Bar#outer_twice")
      refute methods.key?("Bar#gen_pair")
    end
  end

  # What a callee's parameter arrives holding is known only for a call made
  # once, with an array nothing but this body could have changed. A hand-off in
  # a block runs once per pass, the callee pushing onto the array each time; a
  # method DECLARED to return a tuple may hand back an array anyone pushed onto.
  def test_runner_declines_a_hand_off_it_cannot_follow
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          @names: [:a]
          def looped: () -> void
          def outer_loops: (*Symbol) -> void
          def declared: () -> String
          def names: () -> [:a]
          def gen: (Array[Symbol] methods) -> String
        end
      RBS
      write("app/bar.rb", <<~'RUBY')
        class Bar
          def looped = outer_loops(:a)

          def outer_loops(*methods)
            [1, 2].each { gen(methods) }
            nil
          end

          def names = (@names ||= [:a])

          def declared
            names.push(:z)
            gen(names)
          end

          def gen(methods)
            methods << :b
            parts = []
            methods.each { |m| parts << "def #{m}" }
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      refute methods.key?("Bar#gen")
    end
  end

  # An expanded `each` runs its passes in order, so a pass reads what the one
  # before it wrote. The argument fixes `first` and `cur` for the first pass
  # only: decided again on the second, from the write.
  def test_runner_threads_a_loop_pass_into_the_next
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def shout: () -> String
          def label: (bool) -> String
          def echo: (String) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            label(true)
          end

          def shout
            echo("a")
          end

          def label(first)
            parts = []
            ["x", "y"].each do |piece|
              if first
                parts << piece
              else
                parts << "rest"
              end
              first = false
            end
            parts.join(";")
          end

          def echo(cur)
            parts = []
            ["x", "y"].each do |piece|
              parts << cur
              cur = "b"
            end
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"x;rest"' }, methods.fetch("Bar#label"))
      assert_equal({ '("a")' => '"a;b"' }, methods.fetch("Bar#echo"))
    end
  end

  # Each pass rebinds the parameter to the next element, which invalidates the
  # calls cached on it — and a conditional in the body joined them back to the
  # first element's answer. ActiveSupport's `generate` has that shape, and
  # `delegate :a, :b` defined `a` twice.
  def test_runner_binds_each_pass_to_its_own_element_across_a_join
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def greet: () -> String
          def names: (bool) -> String
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def greet
            names(true)
          end

          def names(flag)
            parts = []
            [:x, :y].each do |name|
              suffix = flag ? "!" : "?"
              name = name.to_s
              parts << "\#{name}\#{suffix}"
            end
            parts.join(";")
          end
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(true)" => '"x!;y!"' }, methods.fetch("Bar#names"))
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

  # The other divergence, and the one a generation count was hiding: no new tuple
  # is ever supplied — `f(flag)` calls itself with the same `(true)` — yet the
  # return folds one more `x` every generation. The widening of a return that
  # disagrees with the generation before is what stops it, and `String` is the
  # honest answer: the program does not fix this value.
  def test_runner_widens_a_return_that_keeps_growing
    in_tmpdir do
      write("sig/bar.rbs", <<~RBS)
        class Bar
          def start: () -> String
          def f: (bool) -> "a"
        end
      RBS
      write("app/bar.rb", <<~RUBY)
        class Bar
          def start
            f(true)
          end

          def f(flag)
            if flag
              "\#{f(flag)}x"
            else
              "base"
            end
          end
        end
      RUBY

      methods = Timeout.timeout(120) { Specializations::Runner.run(setup_project) }

      # Nothing recorded is the honest answer: widening took the return back to
      # what the declaration already gives, so there is no specialization to
      # state. Without it the entry was `"axxxxxx"` — one `x` per generation, the
      # value decided by where the loop was cut off.
      assert_empty methods.fetch("Bar#f", {})
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

  # A sidecar entry is TEXT, read back through `RBS::Parser.parse_type`, and a
  # type RBS cannot spell does not survive that round trip — silently, since
  # `singleton_class(::Probe)` parses as the alias `singleton_class`. So what is
  # recorded is what a signature can say.
  def test_runner_records_a_type_a_signature_can_say
    in_tmpdir do
      write("sig/probe.rbs", <<~RBS)
        class Probe
          def self.human_name: (String index) -> String
          def reflect: (bool wrap) -> Array[untyped]
          def call_reflect: () -> Array[untyped]
        end
      RBS
      write("app/probe.rb", <<~RUBY)
        class Probe
          def self.human_name(index) = index

          def reflect(wrap)
            [Probe.singleton_class, wrap]
          end

          def call_reflect = reflect(true)
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)
      recorded = methods.fetch("Probe#reflect").fetch("(true)")

      assert_includes recorded, "::Class"
      refute_match(/singleton_class\(/, recorded)
      # Reads back as the type it says, and stays it.
      parsed = RBS::Parser.parse_type(recorded)
      refute_instance_of RBS::Types::Alias, parsed
      assert_equal parsed.to_s, RBS::Parser.parse_type(parsed.to_s).to_s
    end
  end

  # What that is worth avoiding: the spelling of a type RBS cannot say parses
  # as something else rather than failing.
  def test_a_type_rbs_cannot_say_is_written_as_the_one_it_can
    metaclass = Steep::AST::Types::MetaClass.new(name: RBS::TypeName.parse("::Probe"))
    written = Specializations.rbs_writable(
      Steep::AST::Types::Tuple.new(types: [metaclass, Steep::AST::Types::Literal.new(value: 1)])
    )

    assert_equal "[::Class, 1]", written.to_s
    assert_instance_of RBS::Types::Alias, RBS::Parser.parse_type(metaclass.to_s)
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

    status = Steep::Services::SignatureService.load_from(loader, implicitly_returns_nil: target.implicitly_returns_nil, underscore_casts: target.underscore_casts).status
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
      literal_method_registry: project.literal_method_registry,
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
