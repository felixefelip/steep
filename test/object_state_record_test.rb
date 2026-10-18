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
  RUBY

  SIDECAR = [
    ["Options", "initialize", "@options"],
    ["Autosaved", "initialize", "@options"],
    ["Tweaked", "initialize", "@settings"],
    ["Handed", "initialize", "@options"]
  ].freeze

  def postconditions(rows)
    Steep::Postconditions::Store.from_hash(
      { "postconditions" => rows.map { |klass, method, ivar| { "class" => klass, "method" => method, "effects" => { "may_write" => [ivar] } } } },
      source: "test"
    )
  end

  def check(source_text)
    registry = Steep::Project::ConstructorBindingRegistry.new
    registry.ingest_source(RUBY, path_name: "app.rb")

    with_checker({ "app.rbs" => RBS }, with_stdlib: true) do |checker|
      source = parse_ruby(source_text)

      with_standard_construction(checker, source, constructor_bindings: registry, postconditions: postconditions(SIDECAR)) do |construction, typing|
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

  # Something in the project may change the hash after it is stored: its own
  # method through the ivar, another class through the reader, or one handing
  # the hash on.
  def test_a_hash_the_project_may_change_is_not_held
    check(<<~'RUBY') do |pair|
      autosaved = Autosaved.new({ through: :taggings })
      tweaked = Tweaked.new({ through: :taggings })
      handed = Handed.new({ through: :taggings })
    RUBY
      assert_equal parse_type("::Autosaved"), pair.context.type_env[:autosaved]
      assert_equal parse_type("::Tweaked"), pair.context.type_env[:tweaked]
      assert_equal parse_type("::Handed"), pair.context.type_env[:handed]
    end
  end
end
