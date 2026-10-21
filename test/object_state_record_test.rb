require_relative "test_helper"

# A hash `initialize` binds from an argument, kept in the object's state as the
# record it was built from while nothing can change it (felixefelip/steep#298).
class ObjectStateRecordTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  RBS = <<~RBS
    class Extended
      def self.options: () -> ({ extend: Array[Module] } | {  })
    end
    class Options
      @options: Hash[Symbol, untyped]
      attr_reader options: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] options) -> void
    end
    class Autosaved
      @options: Hash[Symbol, untyped]
      attr_reader options: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] options) -> void
      def autosave!: () -> void
    end
    class Tweaked
      @settings: Hash[Symbol, untyped]
      attr_reader settings: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] settings) -> void
    end
    class Tweaker
      def self.tweak: (Tweaked tweaked) -> void
    end
    class Handed
      @options: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] options) -> void
      def share: () -> void
    end
    class Pruned
      @options: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] options) -> void
      def prune!: () -> void
    end
    class Rekeyed
      @options: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] options) -> void
      def set: (Symbol key, untyped value) -> void
    end
    class Fetched
      @fetched_options: Hash[Symbol, untyped]
      attr_reader fetched_options: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] options) -> void
    end
    class FetchedReader
      def self.read: (Fetched fetched) -> void
    end
    class Aliased
      @aliased_options: Hash[Symbol, untyped]
      attr_reader aliased_options: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] options) -> void
    end
    class Leaked
      @leaked_options: Hash[Symbol, untyped]
      attr_reader leaked_options: Hash[Symbol, untyped]
      def initialize: (Hash[Symbol, untyped] options) -> void
    end
    class Through
      def source: () -> untyped
      def source_options: () -> untyped
      def source_leaked: () -> untyped
      def self.read: (Through through) -> void
    end
  RBS

  RUBY = <<~RUBY
    class Options
      attr_reader :options
      def initialize(options)
        @options = options
      end
    end
    class Autosaved
      attr_reader :options
      def initialize(options)
        @options = options
      end
      def autosave! = @options[:autosave] = true
    end
    class Tweaked
      attr_reader :settings
      def initialize(settings)
        @settings = settings
      end
    end
    class Tweaker
      def self.tweak(tweaked) = tweaked.settings[:tweaked] = true
    end
    class Handed
      def initialize(options)
        @options = options
      end
      def share = Kernel.puts(@options)
    end
    class Pruned
      def initialize(options)
        @options = options
      end
      def prune! = @options.delete(:dependent)
    end
    class Rekeyed
      def initialize(options)
        @options = options
      end
      def set(key, value) = @options[key] = value
    end
    class Fetched
      attr_reader :fetched_options
      def initialize(options)
        @fetched_options = options
      end
    end
    class FetchedReader
      def self.read(fetched)
        fetched.fetched_options.fetch(:through)
        fetched.fetched_options.fetch(:dependent) { :nullify }
        fetched.fetched_options.dig(:through)
        fetched.fetched_options.merge(autosave: true)
        fetched.fetched_options.except(:through)
        fetched.fetched_options.select { |key, _value| :through == key }
        fetched.fetched_options.filter_map { |key, value| :through == value }
      end
    end
    class Aliased
      attr_reader :aliased_options
      def initialize(options)
        @aliased_options = options
      end
    end
    class Leaked
      attr_reader :leaked_options
      def initialize(options)
        @leaked_options = options
      end
    end
    class Through
      def source_options = source.aliased_options
      def source_leaked = source.leaked_options
      def self.read(through)
        options = through.source_options
        options.fetch(:through) if options.key?(:through)
        leaked = through.source_leaked
        Kernel.puts(leaked)
      end
    end
  RUBY

  SIDECAR = [
    ["Options", "initialize", "@options"],
    ["Autosaved", "initialize", "@options"],
    ["Tweaked", "initialize", "@settings"],
    ["Handed", "initialize", "@options"],
    ["Pruned", "initialize", "@options"],
    ["Rekeyed", "initialize", "@options"],
    ["Fetched", "initialize", "@fetched_options"],
    ["Aliased", "initialize", "@aliased_options"],
    ["Leaked", "initialize", "@leaked_options"]
  ].freeze

  def postconditions(rows)
    Steep::Postconditions::Store.from_hash(
      { "postconditions" => rows.map { |klass, method, ivar| { "class" => klass, "method" => method, "effects" => { "may_write" => [ivar] } } } },
      source: "test"
    )
  end

  def check(source_text, reopened: "")
    registry = Steep::Project::ConstructorBindingRegistry.new
    registry.ingest_source(RUBY, path_name: "app.rb")
    literal_methods = Steep::Project::LiteralMethodRegistry.new.ingest_source(reopened, path_name: "reopened.rb")

    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(source_text)

      with_standard_construction(checker, source, constructor_bindings: registry, postconditions: postconditions(SIDECAR), literal_method_registry: literal_methods) do |construction, typing|
        pair = construction.synthesize(source.node)

        assert_no_error typing
        yield pair
      end
    end
  end

  def state(class_name, ivars)
    Steep::AST::Types::ObjectState.new(
      back_type: parse_type(class_name),
      ivars: ivars.transform_values { |type| parse_type(type) }
    )
  end

  def test_a_hash_written_at_new_is_held_as_its_record
    check(<<~'RUBY') do |pair|
      through = Options.new({ through: :taggings })
      plain = Options.new({})
    RUBY
      assert_equal state("::Options", :@options => "{ through: :taggings }"), pair.context.type_env[:through]
      assert_equal state("::Options", :@options => "{ }"), pair.context.type_env[:plain]
    end
  end

  def test_the_reader_answers_the_record_and_a_key_read_answers_its_value
    check(<<~'RUBY') do |pair|
      reflection = Options.new({ through: :taggings })
      through = reflection.options[:through]
      dependent = reflection.options[:dependent]
    RUBY
      assert_equal parse_type(":taggings"), pair.context.type_env[:through]
      assert_equal parse_type("nil"), pair.context.type_env[:dependent]
    end
  end

  def test_a_hash_the_project_writes_by_literal_key_is_held_with_what_the_writes_may_leave
    check(<<~'RUBY') do |pair|
      autosaved = Autosaved.new({ through: :taggings })
      tweaked = Tweaked.new({ through: :taggings })
      pruned = Pruned.new({ through: :taggings, dependent: :nullify })
    RUBY
      assert_equal state("::Autosaved", :@options => "{ through: :taggings, ?autosave: untyped }"), pair.context.type_env[:autosaved]
      assert_equal state("::Tweaked", :@settings => "{ through: :taggings, ?tweaked: untyped }"), pair.context.type_env[:tweaked]
      assert_equal state("::Pruned", :@options => "{ through: :taggings, ?dependent: :nullify }"), pair.context.type_env[:pruned]
    end
  end

  def test_a_hash_the_project_hands_on_or_writes_by_another_key_is_not_held
    check(<<~'RUBY') do |pair|
      handed = Handed.new({ through: :taggings })
      rekeyed = Rekeyed.new({ through: :taggings })
    RUBY
      assert_equal parse_type("::Handed"), pair.context.type_env[:handed]
      assert_equal parse_type("::Rekeyed"), pair.context.type_env[:rekeyed]
    end
  end

  def test_a_reader_used_only_by_reads_and_copies_keeps_the_record
    check(<<~'RUBY') do |pair|
      fetched = Fetched.new({ through: :taggings })
    RUBY
      assert_equal state("::Fetched", :@fetched_options => "{ through: :taggings }"), pair.context.type_env[:fetched]
    end
  end

  # `Through#source_options` answers the reader, and a local holds it.
  def test_a_reader_forwarded_into_a_local_that_only_reads_keeps_the_record
    check(<<~'RUBY') do |pair|
      aliased = Aliased.new({ through: :taggings })
      leaked = Leaked.new({ through: :taggings })
    RUBY
      assert_equal state("::Aliased", :@aliased_options => "{ through: :taggings }"), pair.context.type_env[:aliased]
      assert_equal parse_type("::Leaked"), pair.context.type_env[:leaked]
    end
  end

  # `filter_map` walks the hash by its `each`.
  def test_a_read_the_project_replaced_does_not_keep_the_record
    ["class Hash; def fetch(*) = clear; end", "class Hash; def each(...) = clear; end"].each do |reopened|
      check(<<~'RUBY', reopened: reopened) do |pair|
        fetched = Fetched.new({ through: :taggings })
      RUBY
        assert_equal parse_type("::Fetched"), pair.context.type_env[:fetched], reopened
      end
    end
  end

  # A hash, an array or a string read out of the record can be changed through
  # the name it was read into, so the record holds only its class.
  def test_a_mutable_value_in_the_record_is_held_as_its_class
    check(<<~'RUBY') do |pair|
      reflection = Options.new({ through: { name: :taggings }, list: [:a], class_name: "Post", kind: :plain })
      reflection.options[:through].clear
      through = reflection.options[:through]
      kind = reflection.options[:kind]
    RUBY
      env = pair.context.type_env
      record = "{ through: ::Hash[untyped, untyped], list: ::Array[::Symbol], class_name: ::String, kind: :plain }"
      assert_equal state("::Options", :@options => record), env[:reflection]
      assert_equal parse_type("::Hash[untyped, untyped]"), env[:through]
      assert_equal parse_type(":plain"), env[:kind]
    end
  end

  def test_a_literal_key_written_to_a_record_local_moves_it
    check(<<~'RUBY') do |pair|
      # @type var options: { through: :taggings, counter_cache: true }
      options = _ = nil
      deleted = options.delete(:counter_cache)
      missing = options.delete(:dependent)
      after_delete = options
      options[:autosave] = true
      after_store = options
    RUBY
      env = pair.context.type_env
      assert_equal parse_type("true"), env[:deleted]
      assert_equal parse_type("nil"), env[:missing]
      assert_equal parse_type("{ through: :taggings }"), env[:after_delete]
      assert_equal parse_type("{ through: :taggings, autosave: true }"), env[:after_store]
    end
  end

  def test_a_literal_key_read_on_a_union_of_records_reads_each_record
    check(<<~'RUBY') do |pair|
      options = Extended.options
      through = options[:through]
      extension = options[:extend]
    RUBY
      env = pair.context.type_env
      assert_equal parse_type("nil"), env[:through]
      assert_equal parse_type("::Array[::Module]?"), env[:extension]
    end
  end

  # A call that may change the hash some other way leaves no record to follow.
  def test_a_read_or_a_copy_of_a_record_local_leaves_it
    check(<<~'RUBY') do |pair|
      # @type var options: { through: :taggings }
      options = _ = nil
      options.fetch(:through)
      options.merge(autosave: true)
      options.select { |key, _value| :through == key }
      read = options
    RUBY
      assert_equal parse_type("{ through: :taggings }"), pair.context.type_env[:read]
    end
  end

  def test_any_other_change_to_a_record_local_leaves_a_hash
    check(<<~'RUBY') do |pair|
      # @type var options: { through: :taggings }
      options = _ = nil
      options.merge!({ autosave: true })
      merged = options
      # @type var keyed: { through: :taggings }
      keyed = _ = nil
      # @type var key: Symbol
      key = _ = :x
      keyed[key] = true
      after_open_key = keyed
    RUBY
      env = pair.context.type_env
      refute_kind_of Steep::AST::Types::Record, env[:merged]
      refute_kind_of Steep::AST::Types::Record, env[:after_open_key]
    end
  end
end
