require_relative "test_helper"
require_relative "specializations_project_helper"

class HashNewContentsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def body_types_of(body, initialize: nil)
    in_tmpdir do
      write("app/hash.rb", "class Hash\n#{initialize}\nend\n") if initialize
      write("sig/app.rbs", <<~RBS)
        class Probe
          def fill: (Hash[Symbol, Integer] hash) -> void
          def probe: () -> untyped
        end
      RBS
      write("app/app.rb", <<~RUBY)
        class Probe
          def fill(hash) = hash[:a] = 1

          #{body}
        end
      RUBY
      body_types(setup_project, current_dir + "app/app.rb")
    end
  end

  def probe(lines) = body_types_of("def probe\n#{lines}\nend").fetch("probe")

  def test_a_hash_built_with_a_default_block_holds_no_key
    assert_equal "false", probe("h = Hash.new { |_hash, key| key }\nh.key?(:missing)")
  end

  def test_a_key_written_to_a_hash_built_with_a_default_is_held
    assert_equal "true", probe("h = Hash.new(0)\nh[:a] = 1\nh.key?(:a)")
    assert_equal "1", probe("h = Hash.new(0)\nh[:a] = 1\nh[:a]")
  end

  def test_a_key_the_hash_does_not_hold_is_left_to_the_default
    assert_equal "::Integer", probe("h = Hash.new(0)\nh[:a] = 1\nh[:b]")
  end

  def test_an_initialize_calling_no_hash_method_but_reads_leaves_the_hash_empty
    initialize = <<~RUBY
      def initialize(ifnone = (ifnone_unset = true), capacity: 0, &block)
        raise ArgumentError unless block.nil? || ifnone_unset
      end
    RUBY
    assert_equal "false", body_types_of("def probe\nh = Hash.new(0)\nh.key?(:a)\nend", initialize: initialize).fetch("probe")
  end

  def test_an_initialize_storing_an_entry_leaves_what_the_hash_holds_unknown
    initialize = "def initialize(*) = store(:a, 1)"
    assert_equal "bool", body_types_of("def probe\nh = Hash.new(0)\nh.key?(:a)\nend", initialize: initialize).fetch("probe")
  end

  def test_a_hash_another_name_reaches_holds_what_it_may
    assert_equal "bool", probe("h = Hash.new(0)\ng = h\ng[:a] = 1\nh.key?(:a)")
    assert_equal "bool", probe("h = Hash.new(0)\nfill(h)\nh.key?(:a)")
    assert_equal "bool", probe("h = Hash.new(0)\n[1].each { h[:a] = 1 }\nh.key?(:a)")
  end

  def specialized_types_of(body)
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Hash[unchecked out K, unchecked out V]
          def probe_key: (untyped key) -> bool
          def probe_read: (untyped key) -> untyped
          def probe_after_store: (untyped key) -> bool
          def probe_after_yield: (untyped key) { () -> void } -> bool
        end
        class Probe
          def probe: () -> untyped
        end
      RBS
      write("app/hash.rb", <<~RUBY)
        class Hash
          def probe_key(key) = key?(key)

          def probe_read(key) = self[key]

          def probe_after_store(key)
            store(key, 1)
            key?(key)
          end

          def probe_after_yield(key)
            yield
            key?(key)
          end
        end
      RUBY
      write("app/app.rb", <<~RUBY)
        class Probe
          #{body}
        end
      RUBY
      project = setup_project
      2.times do
        runner = Steep::Specializations::Runner.new(project)
        runner.write(runner.run)
        project.reload_specializations!
      end
      body_types(project, current_dir + "app/app.rb")
    end
  end

  def specialized(lines) = specialized_types_of("def probe\n#{lines}\nend").fetch("probe")

  def test_a_body_checked_for_the_hash_reads_what_it_holds
    assert_equal "true", specialized("h = Hash.new(0)\nh[:a] = 1\nh.probe_key(:a)")
    assert_equal "false", specialized("h = Hash.new(0)\nh[:a] = 1\nh.probe_key(:b)")
    assert_equal "1", specialized("h = Hash.new(0)\nh[:a] = 1\nh.probe_read(:a)")
  end

  def test_a_body_reads_what_it_holds_only_up_to_what_may_change_it
    assert_equal "bool", specialized("h = Hash.new(0)\nh.probe_after_store(:b)")
    assert_equal "bool", specialized("h = Hash.new(0)\nh.probe_after_yield(:b) { h[:b] = 1 }")
  end

  TRANSCRIBED = <<~RUBY
    class Hash
      def initialize(ifnone = (ifnone_unset = true), capacity: 0, &block)
        if block
          raise ArgumentError unless ifnone_unset

          @__rbs_infer__default_proc = block
        else
          @__rbs_infer__ifnone = ifnone
        end
      end

      def default(key = (key_unset = true))
        default_proc = @__rbs_infer__default_proc
        if default_proc
          return nil if key_unset

          return default_proc.call(self, key)
        end

        @__rbs_infer__ifnone
      end
    end
  RUBY

  def defaulted(lines)
    in_tmpdir do
      write("sig/hash.rbs", <<~RBS)
        class Hash[unchecked out K, unchecked out V]
          @__rbs_infer__default_proc: ^(instance, Hash::_Key) -> untyped
        end
        class Probe
          def probe: () -> untyped
        end
      RBS
      write("app/hash.rb", TRANSCRIBED)
      write("app/app.rb", "class Probe\n  def probe\n#{lines}\n  end\nend\n")
      project = setup_project
      2.times do
        runner = Steep::Specializations::Runner.new(project)
        runner.write(runner.run)
        project.reload_specializations!
      end
      body_types(project, current_dir + "app/app.rb").fetch("probe")
    end
  end

  def test_a_key_the_hash_does_not_hold_reads_what_default_answers
    assert_equal '"missing"', defaulted("h = Hash.new { |_hash, key| key.to_s }\nh[:missing]")
    assert_equal "1", defaulted("h = Hash.new { |_hash, key| key.to_s }\nh[:a] = 1\nh[:a]")
  end

  def kept_in_ivar(lines, sigs: "", classes: "", diagnose: nil)
    in_tmpdir do
      write("sig/hash.rbs", <<~RBS)
        class Hash[unchecked out K, unchecked out V]
          @__rbs_infer__default_proc: ^(instance, Hash::_Key) -> untyped
        end
        class Labels
          @backend: Hash[untyped, untyped]
          def initialize: () -> void
          def put: () -> untyped
          def []: (untyped key) -> untyped
        end
        class Exposed
          @backend: Hash[untyped, untyped]
          def initialize: () -> void
          def backend: () -> Hash[untyped, untyped]
          def []: (untyped key) -> untyped
        end
        class Forwarding
          @backend: Hash[untyped, untyped]
          def initialize: () ?{ (untyped, untyped) -> untyped } -> void
          def put: () -> untyped
          def []: (untyped key) -> untyped
          private
          def set_backend: (untyped default_proc) -> untyped
        end
        class Probe
          def probe: () -> untyped
        end
        #{sigs}
      RBS
      write("app/hash.rb", TRANSCRIBED)
      write("app/classes.rb", classes)
      write("app/labels.rb", <<~RUBY)
        class Labels
          def initialize
            @backend = Hash.new { |_hash, key| key.to_s }
          end

          def put = @backend[:a] = 1

          def [](key) = @backend[key]
        end

        class Exposed
          def initialize
            @backend = Hash.new { |_hash, key| key.to_s }
          end

          def backend = @backend

          def [](key) = @backend[key]
        end

        class Forwarding
          def initialize(&default_proc)
            set_backend(default_proc)
          end

          def put = @backend[:a] = 1

          def [](key) = @backend[key]

          private

          def set_backend(default_proc)
            @backend = Hash.new { |_hash, key| default_proc.call(self, key) }
          end
        end
      RUBY
      write("app/app.rb", "class Probe\n  def probe\n#{lines}\n  end\nend\n")
      project = setup_project
      postconditions = Steep::Postconditions::Runner.new(project)
      postconditions.write(postconditions.run)
      project.reload_postconditions!
      3.times do
        runner = Steep::Specializations::Runner.new(project)
        runner.write(runner.run)
        project.reload_specializations!
      end
      next checked(project, current_dir + diagnose).errors.map { |error| error.header_line } if diagnose

      body_types(project, current_dir + "app/app.rb").fetch("probe")
    end
  end

  def test_a_hash_kept_in_an_ivar_is_read_by_what_it_holds_from_another_method
    assert_equal '"missing"', kept_in_ivar("Labels.new[:missing]")
    assert_equal "1", kept_in_ivar("labels = Labels.new\nlabels.put\nlabels[:a]")
  end

  def test_a_hash_kept_in_an_ivar_of_an_object_another_name_reaches_holds_what_it_may
    assert_equal "untyped", kept_in_ivar("labels = Labels.new\nother = labels\nother.put\nlabels[:a]")
  end

  def test_a_hash_kept_in_an_ivar_and_written_through_a_reader_holds_what_it_may
    assert_equal "untyped", kept_in_ivar("exposed = Exposed.new\nexposed.backend[:a] = 1\nexposed[:a]")
  end

  def test_a_hash_whose_default_hands_self_to_a_block_that_never_reads_it_holds_what_it_holds
    assert_equal '"missing"', kept_in_ivar("Forwarding.new { |_map, key| key.to_s }[:missing]")
  end

  def test_a_hash_whose_default_hands_self_to_a_block_that_reads_it_holds_what_it_may
    assert_equal "untyped", kept_in_ivar("Forwarding.new { |map, key| map.put }[:missing]")
  end

  CLASS_HELD_SIGS = <<~RBS
    class Held
      self.@cache: Labels
      def self.cached: (untyped name) -> untyped
      def self.put: () -> untyped
      def self.cache: () -> Labels
      def self.inherited: (untyped subclass) -> untyped
      def self.reveal: (bot value) -> untyped
    end
    class HeldChild < Held
    end
  RBS

  def class_held(lines, set:, also: "", load: "", diagnose: nil)
    kept_in_ivar(lines, sigs: CLASS_HELD_SIGS, diagnose: diagnose, classes: <<~RUBY)
      class Held
        #{set}

        def self.cached(name) = @cache[name]

        #{also}

        def self.reveal(value) = value
      end

      class HeldChild < Held
      end

      #{load}
    RUBY
  end

  HOOK = "def self.inherited(subclass)\n  super\n  subclass.instance_variable_set(:@cache, Labels.new)\nend".freeze

  def revealed(set:, load:, also: "")
    class_held("nil", set: set, also: also, load: load, diagnose: "app/classes.rb").grep(/as an argument of type `bot`/)
  end

  def test_a_hash_an_object_a_class_ivar_holds_is_read_by_what_it_holds
    assert_equal ["Cannot pass a value of type `\"missing\"` as an argument of type `bot`"], revealed(set: "@cache = Labels.new", load: "Held.reveal(Held.cached(:missing))")
  end

  def test_a_hash_an_object_an_inherited_hook_sets_on_a_subclass_is_read_by_what_it_holds
    assert_equal ["Cannot pass a value of type `\"missing\"` as an argument of type `bot`"], revealed(set: HOOK, load: "HeldChild.reveal(HeldChild.cached(:missing))")
  end

  def test_a_hash_an_object_an_inherited_hook_sets_is_read_after_a_write_through_it
    assert_empty revealed(set: HOOK, also: "def self.put = @cache.put", load: "HeldChild.put\nHeldChild.reveal(HeldChild.cached(:a))")
  end

  def test_a_hash_an_object_an_inherited_hook_sets_and_lets_out_holds_what_it_may
    assert_empty revealed(set: HOOK, also: "def self.cache = @cache", load: "HeldChild.cache.put\nHeldChild.reveal(HeldChild.cached(:a))")
  end

  def test_a_hash_an_object_an_inherited_hook_sets_and_writes_through_the_set_s_value_holds_what_it_may
    hook = "def self.inherited(subclass)\n  super\n  cache = subclass.instance_variable_set(:@cache, Labels.new)\n  cache.put\nend"
    assert_empty revealed(set: hook, load: "HeldChild.reveal(HeldChild.cached(:a))")
  end

  def test_a_hash_an_object_a_class_ivar_lets_out_holds_what_it_may
    assert_empty revealed(set: "@cache = Labels.new", also: "def self.cache = @cache", load: "Held.cache.put\nHeld.reveal(Held.cached(:a))")
  end
end
