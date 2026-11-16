require_relative "test_helper"

class CallSiteLocationTest < Minitest::Test
  include TestHelper
  include ShellHelper

  def dirs = (@dirs ||= [])

  def test_a_synthesized_call_with_no_location_is_not_a_call_site
    in_tmpdir do
      (current_dir + "Steepfile").write("target :app do\n  check \"app\"\n  signature \"sig\"\nend\n")
      project = Steep::Project.new(steepfile_path: current_dir + "Steepfile")
      Steep::Project::DSL.parse(project, (current_dir + "Steepfile").read)
      runner = Steep::Specializations::Runner.new(project)
      synthesized = Parser::AST::Node.new(:send, [Parser::AST::Node.new(:send, [nil, :source]), :window])
      locations = {}

      assert_nil runner.send(:record_location, locations, "Source#window", nil, current_dir + "app/app.rb", synthesized, nil)
      assert_empty locations
    end
  end
end
