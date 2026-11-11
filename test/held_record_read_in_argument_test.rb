require_relative "test_helper"
require_relative "specializations_project_helper"

# A record a local holds is handed on as the record it is, where the local is
# read again inside an argument of a call made on it (felixefelip/steep#458),
# or changed there before the call runs (felixefelip/steep#464).
class HeldRecordReadInArgumentTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def through(line, has_records = "has_records")
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        module Refl
          def self.create: (Hash[Symbol, untyped] options) -> untyped
        end
        module Builder
          def self.build: (Hash[Symbol, untyped] options, untyped ext) -> untyped
          def self.pair: (untyped, untyped) -> untyped
        end
        class Model
          def self.has_records: (**untyped) -> untyped
        end
      RBS
      write("app/app.rb", <<~RUBY)
        module Refl
          def self.create(options) = options[:through]
        end

        module Builder
          def self.build(options, ext)
            #{line}
            Refl.create(options)
          end
        end

        class Model
          def self.has_records(**options) = Builder.build(options, nil)
          #{has_records}
        end
      RUBY

      Steep::Specializations::Runner.run(setup_project)["Refl.create"]
    end
  end

  def test_a_local_read_again_inside_an_argument_of_a_store_on_it_hands_on_its_record
    assert_equal({ "({  })" => "nil" }, through("options[:extend] = [*options[:extend], ext] if ext"))
  end

  def test_a_local_changed_inside_an_argument_of_a_call_on_it_hands_on_its_record
    assert_equal({ "({  })" => "nil" }, through("options[:extend] = [*options.delete(:extend), ext] if ext"))
  end

  def test_a_store_is_made_on_the_record_its_argument_left
    assert_equal(
      { "({ :through_was => :posts })" => "nil" },
      through("options[:through_was] = options.delete(:through)", "has_records(through: :posts)")
    )
  end

  def test_a_local_changed_inside_an_argument_of_a_call_it_is_handed_to_hands_on_a_hash
    assert_nil through("Builder.pair(options, options.delete(:extend))")
  end

  def test_a_local_handed_to_a_call_on_itself_hands_on_a_hash
    assert_nil through("options.merge!(options) if ext")
  end
end
