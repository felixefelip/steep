require_relative "../test_helper"

# felixefelip/steep#219: an attr writer has no `def name=` for the inferrer
# to walk, so `AttrWriterInferrer` reads the write it makes from the RBS.
class PostconditionsAttrWriterInferrerTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  Postconditions = Steep::Postconditions

  RBS_FIXTURE = <<~RBS
    class AWAttrs
      @name: Symbol
      @count: Integer
      @label: String
      @computed: String
      self.@level: Integer
      attr_writer name: Symbol
      attr_accessor count: Integer
      attr_reader label: String
      attr_accessor computed (): String
      attr_accessor self.level: Integer
      def rename: (Symbol) -> void
    end

    class AWAttrsSub < AWAttrs
      @tag: String
      attr_writer tag: String
      def reset: () -> void
    end
  RBS

  def infer_for(ruby)
    entries = nil
    with_checker(RBS_FIXTURE) do |checker|
      source = parse_ruby(ruby)
      with_standard_construction(checker, source) do |construction, typing|
        construction.synthesize(source.node)
        entries = Postconditions::Inferrer.infer(source, typing, checker)
      end
    end
    entries
  end

  # Instance and singleton alike. An attr without a backing ivar
  # (`ivar_name: false`) writes none, and a reader writes nothing.
  def test_an_attr_writer_may_write_its_ivar
    entries = infer_for(<<~RUBY)
      class AWAttrs
        attr_writer :name
        attr_accessor :count
        attr_reader :label
        class << self
          attr_accessor :level
        end
      end
    RUBY

    writers = entries.to_h { |entry| [[entry.method_name, entry.singleton], entry.may_write_ivars] }
    assert_equal(
      {
        [:name=, false] => Set[:@name],
        [:count=, false] => Set[:@count],
        [:level=, true] => Set[:@level]
      },
      writers
    )
  end

  # A method that writes through the attr names it as a self-call, and the
  # Runner's closure carries the attr's write into it.
  def test_a_write_through_an_attr_writer_is_a_self_call_to_it
    entries = infer_for(<<~RUBY)
      class AWAttrs
        attr_writer :name
        def rename(name)
          self.name = name
        end
      end
    RUBY

    rename = entries.find { |entry| entry.method_name == :rename }
    assert_equal Set["AWAttrs#name="], rename.self_call_deps
    assert_equal Set[:@name], entries.find { |entry| entry.method_name == :name= }.may_write_ivars
  end

  # An inherited writer is recorded where it is declared, not on each
  # subclass that opens; the subclass's own writer is.
  def test_an_inherited_attr_writer_is_not_recorded_on_the_subclass
    entries = infer_for(<<~RUBY)
      class AWAttrsSub < AWAttrs
        attr_writer :tag
        def reset = nil
      end
    RUBY

    writers = entries.to_h { |entry| [[entry.class_name, entry.method_name], entry.may_write_ivars] }
    assert_equal({ ["AWAttrsSub", :tag=] => Set[:@tag] }, writers)
  end
end
