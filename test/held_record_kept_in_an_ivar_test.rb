require_relative "test_helper"
require_relative "specializations_project_helper"

# A parameter its method returns is held up to the return, and a local whose
# record a call answers into an ivar of `self` keeps following the record,
# widened by every write a body may make through the ivar
# (felixefelip/steep#465).
class HeldRecordKeptInAnIvarTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def create_after(initialize_body, other_methods = "", subclass_body = "")
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Macro
          @options: Hash[Symbol, untyped]
          @klass: untyped
          @other: untyped
          def initialize: (Hash[Symbol, untyped] options) -> void
          def normalize: (Hash[Symbol, untyped] options) -> Hash[Symbol, untyped]
          def mark: () -> void
          def options: () -> Hash[Symbol, untyped]
        end
        class Assoc < Macro
          def initialize: (Hash[Symbol, untyped] options) -> void
          def remark: () -> void
        end
        module Refl
          def self.create: (Hash[Symbol, untyped] options) -> untyped
        end
        class Model
          def self.has_records: (**untyped) -> untyped
        end
      RBS
      write("app/app.rb", <<~RUBY)
        class Macro
          def initialize(options)
            #{initialize_body}
            @klass = options[:anonymous_class]
          end

          def normalize(options)
            options.delete(:counter_cache)
            options
          end

          #{other_methods}
        end

        class Assoc < Macro
          #{subclass_body}
        end

        module Refl
          def self.create(options)
            Assoc.new(options)
            options[:through]
          end
        end

        class Model
          def self.has_records(**options) = Refl.create(options)
          has_records
        end
      RUBY

      Steep::Specializations::Runner.run(setup_project)["Refl.create"]
    end
  end

  def test_a_parameter_its_method_returns_is_handed_back
    assert_equal({ "({  })" => "nil" }, create_after("normalize(options)"))
  end

  def test_a_record_answered_into_an_ivar_nothing_writes_is_followed
    assert_equal({ "({  })" => "nil" }, create_after("@options = normalize(options)"))
  end

  def test_a_record_answered_into_an_ivar_a_reader_hands_out_to_reads_is_followed
    assert_equal({ "({  })" => "nil" }, create_after("@options = normalize(options)", "attr_reader :options\ndef label = options[:as]"))
  end

  def test_a_write_through_the_ivar_in_another_method_widens_the_record
    refute_equal({ "({  })" => "nil" }, create_after("@options = normalize(options)", "def mark = @options[:through] = :posts"))
  end

  def test_a_write_through_the_ivar_in_a_subclass_widens_the_record
    refute_equal({ "({  })" => "nil" }, create_after("@options = normalize(options)", "", "def remark = @options[:through] = :posts"))
  end

  def test_a_write_through_the_ivar_in_an_initializer_widens_the_record
    subclass = "def initialize(options)\nsuper\n@options[:through] = :posts\nend"

    refute_equal({ "({  })" => "nil" }, create_after("@options = normalize(options)", "", subclass))
  end

  def test_a_write_through_a_reader_widens_the_record
    refute_equal({ "({  })" => "nil" }, create_after("@options = normalize(options)", "attr_reader :options\ndef mark = options[:through] = :posts"))
  end

  def test_a_record_answered_into_an_ivar_and_taken_again_is_not_followed
    refute_equal({ "({  })" => "nil" }, create_after("@other = @options = normalize(options)"))
  end
end
