require_relative "test_helper"

class FramedCallSitesTest < Minitest::Test
  include TestHelper
  include ShellHelper

  def dirs = (@dirs ||= [])

  RBS = <<~RBS
    class Labels
      def self.pick: (singleton(Sub) owner, Symbol name) -> Symbol
      def self.label: (Symbol name) -> Symbol
      def self.kind: () -> :base
    end
    class Sub < Labels
      def self.kind: () -> :sub
    end
  RBS

  RUBY = <<~RUBY
    class Labels
      def self.pick(owner, name) = owner.label(name)
      def self.label(name) = kind
      def self.kind = :base
    end

    class Sub < Labels
      def self.kind = :sub
    end
  RUBY

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
  end

  def label_tuples(calls, rbs: RBS, ruby: RUBY, key: "Labels.label")
    in_tmpdir do
      write("sig/app.rbs", rbs)
      write("app/app.rb", ruby + calls)
      steepfile = "target :app do\n  signature \"sig\"\n  check \"app\"\nend\n"
      write("Steepfile", steepfile)
      project = Steep::Project.new(steepfile_path: current_dir + "Steepfile")
      Steep::Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
      return Steep::Specializations::Runner.new(project).run.fetch(key, {}).keys.sort
    end
  end

  def test_a_call_inside_a_body_every_call_of_which_is_read_is_read_only_under_those_calls
    assert_equal ["(:x) on singleton(::Sub)"], label_tuples("Labels.pick(Sub, :x)\n")
  end

  def test_a_call_inside_a_body_one_call_of_which_is_not_known_is_read_under_the_declarations_too
    assert_equal ["(::Symbol) on singleton(::Sub)", "(:x) on singleton(::Sub)"], label_tuples("Labels.pick(Sub, :x)\nLabels.pick(Sub, [:y].sample || :y)\n")
  end

  def test_a_call_inside_a_body_whose_own_call_is_made_in_a_body_no_tuple_rechecks_is_read_under_the_declarations
    rbs = <<~RBS
      class Host
        def record: (String message) -> String
        def refuse: () -> String
      end
      module Responder
        def self.deny: (Host host, "denied" message) -> String
      end
    RBS
    ruby = <<~RUBY
      class Host
        def record(message) = message
        def refuse = Responder.deny(self, "denied")
      end

      module Responder
        def self.deny(host, message) = host.record(message)
      end
    RUBY

    assert_equal ['("denied")'], label_tuples("Host.new.refuse\n", rbs: rbs, ruby: ruby, key: "Host#record")
  end
end
