require_relative "test_helper"

class SpecializationsReceiversTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper

  Receivers = Steep::Specializations::Receivers

  SIGNATURES = <<~RBS
    module Shared
    end
    class Base
    end
    class Reflection < Base
    end
    class Through < Reflection
    end
    class Status
    end
  RBS

  def test_the_classes_a_type_names
    with_factory do
      assert_equal ["::Status"], Receivers.classes(parse_type("::Status"))
      assert_equal ["singleton(::Status)"], Receivers.classes(parse_type("singleton(::Status)"))
      assert_equal ["::Status", "::NilClass"], Receivers.classes(parse_type("::Status?"))
      assert_equal ["::Symbol"], Receivers.classes(parse_type(":a"))
      assert_nil Receivers.classes(parse_type("untyped"))
      assert_nil Receivers.classes(parse_type("::Status | untyped"))
    end
  end

  def test_a_receiver_may_be_an_instance_of_its_ancestors_and_descendants_and_any_module
    with_checker({ "a.rbs" => SIGNATURES }) do |checker|
      builder = checker.factory.definition_builder
      reflection = RBS::TypeName.parse("::Reflection")

      %w[::Reflection ::Base ::Through ::Shared ::Object].each do |klass|
        assert Receivers.may_be?(builder, [klass], reflection), klass
      end
      ["::Status", "singleton(::Reflection)", "::NilClass"].each do |klass|
        refute Receivers.may_be?(builder, [klass], reflection), klass
      end
      assert Receivers.may_be?(builder, ["::Status", "::Base"], reflection)
      assert Receivers.may_be?(builder, ["singleton(::Reflection)"], RBS::TypeName.parse("::Class"))
    end
  end
end
