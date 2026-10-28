require_relative "test_helper"
require_relative "specializations_project_helper"

class ObjectMemoMapTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  MUTEX = <<~RUBY
    class Thread::Mutex
      def synchronize
        raise ThreadError, "must be called with a block" unless block_given?

        lock
        begin
          yield
        ensure
          unlock
        end
      end
    end
  RUBY

  BACKEND = <<~RUBY
    class MBackend
      def initialize(options = nil, &default_proc)
        set_backend(default_proc)
        @default_proc = default_proc
      end

      def [](key)
        @backend[key]
      end

      def []=(key, value)
        @backend[key] = value
      end

      private

      def set_backend(default_proc)
        if default_proc
          @backend = ::Hash.new { |_h, key| default_proc.call(self, key) }
        else
          @backend = {}
        end
      end
    end

    class MLocked < MBackend
      def initialize(options = nil, &default_proc)
        super(options, &default_proc)
        @write_lock = Mutex.new
      end

      def []=(key, value)
        @write_lock.synchronize { super }
      end
    end
  RUBY

  RBS = <<~RBS
    class MBackend
      @backend: Hash[untyped, untyped]
      @default_proc: untyped
      def initialize: (?untyped options) ?{ (untyped, untyped) -> untyped } -> void
      def []: (untyped key) -> untyped
      def []=: (untyped key, untyped value) -> untyped
      private
      def set_backend: (untyped default_proc) -> untyped
    end
    class MLocked < MBackend
      @write_lock: Thread::Mutex
      def initialize: (?untyped options) ?{ (untyped, untyped) -> untyped } -> void
      def []=: (untyped key, untyped value) -> untyped
    end
    class MMap[K, V] < MLocked
      def []: (K key) -> V?
      def []=: (K key, V value) -> V
    end
    class MUse
      self.@memo: MMap[untyped, untyped]
      def self.read: () -> untyped
    end
  RBS

  USE = <<~RUBY
    class MUse
      @memo = MMap.new
      def self.read = (@memo[:a] ||= :x)
      read
    end
  RUBY

  def test_a_memo_reads_back_what_a_store_made_through_a_synchronize_block_s_super_left
    assert_equal "::Symbol", read(map: "class MMap < MLocked\nend\n")
  end

  def test_declines_a_store_in_a_block_a_method_that_names_its_block_runs
    mutex = MUTEX.sub("def synchronize", "def synchronize(&block)\n    @block = block")

    assert_nil read(map: "class MMap < MLocked\nend\n", mutex: mutex)
  end

  def test_a_store_runs_the_body_the_source_inherits_where_the_rbs_declares_the_method_on_the_subclass
    assert_equal "::Symbol", read(map: "class MMap < MLocked\nend\n", rbs: RBS.sub("    def []: (K key) -> V?\n", ""))
  end

  def test_an_alias_of_a_body_the_source_defines_writes_what_that_body_writes
    map = "class MMap < MLocked\n  alias_method :get, :[]\n  alias_method :put, :[]=\nend\n"

    assert_equal "::Symbol", read(map: map, rbs: with_map_methods("def get: (K key) -> V?", "def put: (K key, V value) -> V"))
  end

  def test_a_def_in_a_class_body_branch_writes_what_its_body_writes
    map = <<~RUBY
      class MMap < MLocked
        def fill(key, value)
          self[key] = value
        end unless method_defined?(:fill)
      end
    RUBY

    assert_equal "::Symbol", read(map: map, rbs: with_map_methods("def fill: (K key, V value) -> V"))
  end

  def test_declines_a_def_in_a_class_body_branch_that_replaces_the_hash
    map = <<~RUBY
      class MMap < MLocked
        def wipe
          @backend = nil
        end unless method_defined?(:wipe)
      end
    RUBY

    assert_nil read(map: map, rbs: with_map_methods("def wipe: () -> void"))
  end

  def test_a_clear_that_answers_self_is_a_write_the_hash_follows
    backend = BACKEND.sub("      private\n", "      def clear\n        @backend.clear\n        self\n      end\n\n      private\n")
    rbs = RBS.sub("      private\n", "      def clear: () -> self\n      private\n")

    assert_equal "::Symbol", read(map: "class MMap < MLocked\nend\n", backend: backend, rbs: rbs)
  end

  def test_a_copy_hook_s_calls_on_self_initialize_the_copy
    backend = BACKEND.sub("      private\n", "      private\n\n      def initialize_copy(other)\n        super\n        set_backend(@default_proc)\n        self\n      end\n")
    rbs = RBS.sub("      private\n", "      private\n      def initialize_copy: (untyped other) -> self\n")

    assert_equal "::Symbol", read(map: "class MMap < MLocked\nend\n", backend: backend, rbs: rbs)
  end

  def test_an_initialize_the_class_body_never_defines_runs_the_inherited_one
    map = <<~RUBY
      class MMap < MLocked
        unless defined?(MLocked) and self < MLocked
          def initialize
            @backend = nil
          end
        end
      end
    RUBY

    assert_equal "::Symbol", read(map: map, rbs: with_map_methods("def initialize: () -> void"))
  end

  CLEARING_RBS = <<~RBS
    class CBox
      @items: Hash[Symbol, Symbol]
      def initialize: () -> void
      def []: (Symbol key) -> Symbol?
      def []=: (Symbol key, Symbol value) -> Symbol
      def clear: () -> self
    end
    class CUse
      def plain: () -> untyped
      def aliased: () -> untyped
    end
  RBS

  CLEARING = <<~RUBY
    class CBox
      def initialize
        @items = {}
      end

      def [](key) = @items[key]

      def []=(key, value)
        @items[key] = value
      end

      def clear
        @items.clear
        self
      end
    end

    class CUse
      def plain
        box = CBox.new
        box[:a] = :x
        box[:a]
      end

      def aliased
        box = CBox.new
        other = box.clear
        other[:a] = :x
        box[:a]
      end
    end
  RUBY

  def test_a_call_that_may_answer_self_ends_what_the_variable_follows_where_its_value_is_taken
    in_tmpdir do
      write("sig/box.rbs", CLEARING_RBS)
      write("app/box.rb", CLEARING)
      types = specialized_body_types("app/box.rb")

      assert_equal ":x", types.fetch("plain")
      refute_equal "nil", types.fetch("aliased")
    end
  end

  private

  def with_map_methods(*methods)
    RBS.sub("    def []=: (K key, V value) -> V\n", "    def []=: (K key, V value) -> V\n#{methods.map { |method| "    #{method}\n" }.join}")
  end

  def read(map:, rbs: RBS, backend: BACKEND, mutex: MUTEX)
    in_tmpdir do
      write("sig/map.rbs", rbs)
      write("app/map.rb", mutex + backend + map + USE)
      project = setup_project
      postconditions = Steep::Postconditions::Runner.new(project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.write(runner.run)
      return YAML.safe_load_file(current_dir + "sig/generated/.steep_specializations.yml").dig("declarations", "MUse.read")
    end
  end

  def specialized_body_types(path)
    project = setup_project
    postconditions = Steep::Postconditions::Runner.new(project)
    postconditions.write(postconditions.run)
    project = setup_project
    runner = Steep::Specializations::Runner.new(project)
    runner.write(runner.run)
    project.reload_specializations!

    body_types(project, current_dir + path)
  end
end
