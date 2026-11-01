require_relative "test_helper"
require_relative "specializations_project_helper"

# A record a parameter holds is handed on by `super` as the record it is, and
# what the parent's body leaves it holding is handed back
# (felixefelip/steep#463).
class HeldRecordThroughSuperTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def through(super_call)
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Macro
          @klass: untyped
          def initialize: (Hash[Symbol, untyped] options) -> void
        end
        class Assoc < Macro
          def initialize: (Hash[Symbol, untyped] options) -> void
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
            options.delete(:counter_cache)
            @klass = options[:anonymous_class]
          end
        end

        class Assoc < Macro
          def initialize(options)
            #{super_call}
          end
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

      Steep::Specializations::Runner.run(setup_project).values_at("Refl.create", "Macro#initialize")
    end
  end

  def test_a_bare_super_hands_on_the_record
    create, parent = through("super")

    assert_equal({ "({  })" => "nil" }, create)
    assert_equal ["({  }) with {@klass: nil}"], parent.keys
  end

  def test_an_explicit_super_hands_on_the_record
    create, parent = through("super(options)")

    assert_equal({ "({  })" => "nil" }, create)
    assert_equal ["({  }) with {@klass: nil}"], parent.keys
  end
end
