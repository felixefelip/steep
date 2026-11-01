require_relative "test_helper"
require_relative "specializations_project_helper"

# A record a local holds is handed on as the record it is, where the local is
# read again inside an argument of a call made on it (felixefelip/steep#458).
class HeldRecordReadInArgumentTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def through(line)
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        module Refl
          def self.create: (Hash[Symbol, untyped] options) -> untyped
        end
        module Builder
          def self.build: (Hash[Symbol, untyped] options, untyped ext) -> untyped
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
          has_records
        end
      RUBY

      Steep::Specializations::Runner.run(setup_project)["Refl.create"]
    end
  end

  def test_a_local_read_again_inside_an_argument_of_a_store_on_it_hands_on_its_record
    assert_equal({ "({  })" => "nil" }, through("options[:extend] = [*options[:extend], ext] if ext"))
  end

  def test_a_local_changed_inside_an_argument_of_a_call_on_it_hands_on_a_hash
    assert_nil through("options[:extend] = [*options.delete(:extend), ext] if ext")
  end

  def test_a_local_handed_to_a_call_on_itself_hands_on_a_hash
    assert_nil through("options.merge!(options) if ext")
  end
end
