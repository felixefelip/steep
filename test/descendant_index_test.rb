require_relative "test_helper"

class DescendantIndexTest < Minitest::Test
  include TestHelper
  include FactoryHelper

  SIGNATURES = {
    "hierarchy.rbs" => <<~RBS
      class Root
      end
      class Middle < Root
      end
      class LeafOne < Middle
      end
      class LeafTwo < Middle
      end
      class Elsewhere
      end
      module Mixed
      end
      class Includer
        include Mixed
      end
    RBS
  }

  def index
    with_factory(SIGNATURES, nostdlib: false) { |factory| yield factory.descendant_index }
  end

  def names(list)
    list&.map(&:to_s)&.sort
  end

  def test_every_class_below_one_transitively
    index do |descendants|
      assert_equal ["::LeafOne", "::LeafTwo", "::Middle"], names(descendants.descendants(RBS::TypeName.parse("::Root"), limit: 10))
      assert_equal ["::LeafOne", "::LeafTwo"], names(descendants.descendants(RBS::TypeName.parse("::Middle"), limit: 10))
      assert_equal [], names(descendants.descendants(RBS::TypeName.parse("::LeafOne"), limit: 10))
      assert_equal [], names(descendants.descendants(RBS::TypeName.parse("::Elsewhere"), limit: 10))
    end
  end

  # A class that includes a module is not one OF it: `Mixed.instance_method(:x)`
  # reflects what Mixed itself writes, whatever includes it.
  def test_a_module_has_none
    index do |descendants|
      assert_equal [], names(descendants.descendants(RBS::TypeName.parse("::Mixed"), limit: 10))
    end
  end

  # A class with no superclass written is a subclass of `Object`, so the root of
  # the world is where the bound is spent rather than the answer.
  def test_past_the_limit_there_is_no_answer
    index do |descendants|
      assert_nil descendants.descendants(RBS::TypeName.parse("::Root"), limit: 2)
      assert_nil descendants.descendants(RBS::TypeName.parse("::Object"), limit: 10)
    end
  end
end
