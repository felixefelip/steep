require_relative "test_helper"
require_relative "specializations_project_helper"

class IvarsAssignedTogetherTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def read_after(initialize_body, reader = "acronyms[w]")
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Rules
          @plurals: Array[untyped]
          @acronyms: Hash[String, String]
          attr_reader acronyms: Hash[String, String]
          attr_reader plurals: Array[untyped]
          def initialize: () -> void
        end
        module Probe
          def self.go: (String w) -> untyped
        end
        class Post
          X: untyped
        end
      RBS
      write("app/app.rb", <<~RUBY)
        class Rules
          attr_reader :acronyms
          attr_reader :plurals
          def initialize
            #{initialize_body}
          end
        end

        module Probe
          def self.go(w) = Rules.new.#{reader}
        end

        class Post
          X = Probe.go("comment")
        end
      RUBY

      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      Steep::Specializations::Runner.run(setup_project)["Probe.go"]
    end
  end

  def test_an_ivar_assigned_alone_holds_what_it_is_assigned
    assert_equal({ '("comment")' => "nil" }, read_after("@acronyms = {}"))
  end

  def test_ivars_assigned_together_hold_what_each_is_assigned
    assert_equal({ '("comment")' => "nil" }, read_after("@plurals, @acronyms = [], {}"))
    assert_equal({ '("comment")' => "{  }" }, read_after("@plurals, @acronyms = [], {}", "acronyms"))
    assert_equal({ '("comment")' => "nil" }, read_after("@acronyms, @plurals = {}, []"))
  end

  def test_declines_ivars_assigned_from_a_splat
    assert_nil read_after("pair = [[], {}]\n    @plurals, @acronyms = *pair")
  end
end
