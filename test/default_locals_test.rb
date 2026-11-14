require_relative "test_helper"
require_relative "specializations_project_helper"

class DefaultLocalsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def body_types_of(body)
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Picker
          def unset?: (?Symbol key) -> untyped
          def probe: () -> untyped
        end
      RBS
      write("app/app.rb", <<~RUBY)
        class Picker
          def unset?(key = (unset = true)) = unset

          #{body}
        end
      RUBY
      project = setup_project
      2.times do
        runner = Steep::Specializations::Runner.new(project)
        runner.write(runner.run)
        project.reload_specializations!
      end
      body_types(project, current_dir + "app/app.rb")
    end
  end

  def test_a_local_the_default_assigns_is_nil_where_the_call_passes_the_parameter
    assert_equal "nil", body_types_of("def probe = unset?(:a)").fetch("probe")
  end

  def test_a_local_the_default_assigns_may_be_nil_in_the_body_checked_for_every_call
    assert_equal "(bool | nil)", body_types_of("def probe = nil").fetch("unset?")
  end
end
