require_relative "../test_helper"

# felixefelip/steep#228: an attribute a method always writes on one of its
# parameters reaches the call site. The parameter sibling of
# `returns.establishes` (#56).
class PostconditionsParamEstablishmentTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  Postconditions = Steep::Postconditions

  RBS = <<~RBS
    class PEBox
      attr_accessor value: :draft | :published
      def initialize: (:draft | :published) -> void
      def stamp!: () -> void
    end

    class PEPublisher
      def publish: (PEBox box) -> void
      def log: (PEBox box) -> void
      def publish_last: (*PEBox others, PEBox box) -> void
      def publish_first: (PEBox box, *PEBox others) -> void
      def publish_both: (PEBox first, PEBox second) -> void
      def publish_after_default: (?PEBox fallback, PEBox box) -> void
      def ready?: () -> bool
      def maybe: () -> PEPublisher?
      def run: () -> untyped
    end

    class PEStamper
      def self.publish: (PEBox box) -> void
    end

    class PEBothSides
      def publish: (PEBox box) -> void
      def self.publish: (PEBox box) -> void
    end
  RBS

  def infer_for(ruby)
    entries = nil
    with_checker(RBS) do |checker|
      source = parse_ruby(ruby)
      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)
        entries = Postconditions::Inferrer.infer(source, typing, checker)
      end
    end
    entries
  end

  def establishments_of(entries, method_name)
    entry = entries.find { |e| e.method_name == method_name } or return {}
    entry.param_establishments.transform_values { |attrs| attrs.transform_values(&:to_s) }
  end

  def test_infers_the_value_written_on_a_parameter
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish(box)
          box.value = :published
        end
      end
    RUBY

    assert_equal({ 0 => { value: ":published" } }, establishments_of(entries, :publish))
  end

  def test_infers_it_for_a_singleton_method
    entries = infer_for(<<~RUBY)
      class PEStamper
        def self.publish(box)
          box.value = :published
        end
      end
    RUBY

    entry = entries.find { |e| e.method_name == :publish }
    assert entry.singleton
    assert_equal({ 0 => { value: ":published" } }, establishments_of(entries, :publish))
  end

  def test_a_reader_after_the_write_keeps_it
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish(box)
          box.value = :published
          box.value
        end
      end
    RUBY

    assert_equal({ 0 => { value: ":published" } }, establishments_of(entries, :publish))
  end

  def test_a_write_in_a_branch_establishes_nothing
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish(box)
          if ready?
            box.value = :published
          end
        end
      end
    RUBY

    assert_empty establishments_of(entries, :publish)
  end

  def test_handing_the_parameter_on_after_the_write_drops_it
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish(box)
          box.value = :published
          log(box)
        end
      end
    RUBY

    assert_empty establishments_of(entries, :publish)
  end

  def test_calling_a_method_on_the_parameter_after_the_write_drops_it
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish(box)
          box.value = :published
          box.stamp!
        end
      end
    RUBY

    assert_empty establishments_of(entries, :publish)
  end

  def test_reassigning_the_parameter_drops_it
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish(box)
          box.value = :published
          box = PEBox.new(:draft)
        end
      end
    RUBY

    assert_empty establishments_of(entries, :publish)
  end

  def test_an_early_return_establishes_nothing
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish(box)
          return unless ready?
          box.value = :published
        end
      end
    RUBY

    assert_empty establishments_of(entries, :publish)
  end

  def test_a_parameter_after_a_splat_establishes_nothing
    entries = infer_for(<<~RUBY)
      class PEPublisher
        # Steep leaves a parameter after a splat untyped; the annotation
        # stands in for a checker that types it.
        # @type var box: PEBox
        def publish_last(*others, box)
          box.value = :published
        end
      end
    RUBY

    assert_empty establishments_of(entries, :publish_last)
  end

  def test_a_parameter_before_a_splat_keeps_its_position
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish_first(box, *others)
          box.value = :published
        end
      end
    RUBY

    assert_equal({ 0 => { value: ":published" } }, establishments_of(entries, :publish_first))
  end

  def test_a_later_write_through_another_parameter_takes_the_reader
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish_both(first, second)
          first.value = :published
          second.value = :draft
        end
      end
    RUBY

    # `publish_both(box, box)` leaves `:draft`: only the last write survives.
    assert_equal({ 1 => { value: ":draft" } }, establishments_of(entries, :publish_both))
  end

  def test_an_optional_parameter_before_a_required_one_ends_the_positions
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish_after_default(fallback = PEBox.new(:draft), box)
          fallback.value = :published
        end
      end
    RUBY

    # `publish_after_default(box)` binds `box`, not `fallback`, to position 0.
    assert_empty establishments_of(entries, :publish_after_default)
  end

  def test_a_value_as_wide_as_the_reader_establishes_nothing
    entries = infer_for(<<~RUBY)
      class PEPublisher
        def publish(box)
          box.value = box.value
        end
      end
    RUBY

    assert_empty establishments_of(entries, :publish)
  end

  def test_the_writer_round_trips_the_slot
    entry = Postconditions::InferredEntry.new(
      class_name: "PEPublisher", method_name: :publish, singleton: true,
      param_establishments: { 0 => { value: Steep::AST::Types::Literal.new(value: :published) } }
    )
    raw = YAML.safe_load(Postconditions::Writer.dump([entry]))
    assert_equal({ 0 => { "value" => ":published" } }, raw["postconditions"].first.dig("unconditional", "params"))

    store = Postconditions::Store.from_hash(raw, source: "<test>")
    branch = store.lookup_instance("PEPublisher", :publish).unconditional
    assert_equal ":published", branch.param_establishes_rbs_types.dig(0, :value).to_s
  end

  def publish_postcondition(type: ":published", attr: "value", klass: "PEPublisher")
    Postconditions::Store.from_hash(
      {
        "version" => 1,
        "postconditions" => [
          { "class" => klass, "method" => "publish", "unconditional" => { "params" => { 0 => { attr => type } } } }
        ]
      },
      source: "<test>"
    )
  end

  def value_type_after(ruby, postconditions:)
    type = nil
    with_checker(RBS) do |checker|
      source = parse_ruby(ruby)
      with_standard_construction(checker, source, postconditions: postconditions) do |construction, typing|
        construction.synthesize(source.node)
        last = source.node.children[2].children.last
        type = typing.type_of(node: last)
      end
    end
    type
  end

  def test_the_call_site_reads_what_the_callee_wrote
    type = value_type_after(<<~RUBY, postconditions: publish_postcondition)
      # @type self: ::PEPublisher
      def run
        box = PEBox.new(:draft)
        publish(box)
        box.value
      end
    RUBY

    assert_equal ":published", type.to_s
  end

  def test_a_singleton_call_site_reads_it_too
    type = value_type_after(<<~RUBY, postconditions: publish_postcondition(klass: "PEStamper"))
      # @type self: ::PEPublisher
      def run
        box = PEBox.new(:draft)
        PEStamper.publish(box)
        box.value
      end
    RUBY

    assert_equal ":published", type.to_s
  end

  def test_a_name_on_both_sides_establishes_nothing
    # The entry cannot say whether `publish` or `self.publish` wrote it.
    [["publish(box)", "instance"], ["PEBothSides.publish(box)", "singleton"]].each do |call, side|
      type = value_type_after(<<~RUBY, postconditions: publish_postcondition(klass: "PEBothSides"))
        # @type self: ::PEBothSides
        def run
          box = PEBox.new(:draft)
          #{call}
          box.value
        end
      RUBY

      assert_equal "(:draft | :published)", type.to_s, side
    end
  end

  def test_the_call_replaces_a_narrowing_made_before_it
    type = value_type_after(<<~RUBY, postconditions: publish_postcondition(klass: "PEStamper"))
      # @type self: ::PEPublisher
      def run
        box = PEBox.new(:draft)
        box.value = :draft
        PEStamper.publish(box)
        box.value
      end
    RUBY

    assert_equal ":published", type.to_s
  end

  def test_without_the_entry_the_reader_is_declared
    type = value_type_after(<<~RUBY, postconditions: Postconditions::Store.empty)
      # @type self: ::PEPublisher
      def run
        box = PEBox.new(:draft)
        publish(box)
        box.value
      end
    RUBY

    assert_equal "(:draft | :published)", type.to_s
  end

  def test_a_value_the_reader_cannot_hold_is_ignored
    type = value_type_after(<<~RUBY, postconditions: publish_postcondition(type: ":archived"))
      # @type self: ::PEPublisher
      def run
        box = PEBox.new(:draft)
        publish(box)
        box.value
      end
    RUBY

    assert_equal "(:draft | :published)", type.to_s
  end

  def test_a_call_that_may_not_run_establishes_nothing
    type = value_type_after(<<~RUBY, postconditions: publish_postcondition)
      # @type self: ::PEPublisher
      def run
        box = PEBox.new(:draft)
        maybe&.publish(box)
        box.value
      end
    RUBY

    assert_equal "(:draft | :published)", type.to_s
  end

  def test_a_write_after_the_call_wins
    type = value_type_after(<<~RUBY, postconditions: publish_postcondition)
      # @type self: ::PEPublisher
      def run
        box = PEBox.new(:draft)
        publish(box)
        box.value = :draft
        box.value
      end
    RUBY

    assert_equal ":draft", type.to_s
  end
end
