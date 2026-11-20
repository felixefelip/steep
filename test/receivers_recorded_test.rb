require_relative "test_helper"
require_relative "specializations_project_helper"

class ReceiversRecordedTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class Job
      @count: Integer
      def initialize: () -> void
      def call: () -> Integer
    end
    class Box
      @count: Integer
      @default: (^(self, Symbol) -> Integer)?
      @maker: ^(instance) -> Integer
      def initialize: () -> void
      def peer: () -> self
      def call: () -> Integer
      def run_default: () -> Integer?
      def run_maker: () -> Integer
      def run_peer: () -> Integer
    end
  RBS

  RUBY = <<~RUBY
    class Job
      def initialize
        @count = 1
      end

      def call = @count
    end

    class Box
      def initialize
        @count = 3
        @default = nil
        @maker = ->(box) { 2 }
      end

      def peer = self
      def call = @count

      def run_default = @default&.call(self, :k)
      def run_maker = @maker.call(self)
      def run_peer = peer.call
    end
  RUBY

  def run_runner
    in_tmpdir do
      write("sig/box.rbs", RBS)
      write("app/box.rb", RUBY)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      return yield(runner)
    end
  end

  def receiver_at(runner, snippet)
    line = RUBY.lines.index { |text| text.include?(snippet) } + 1
    runner.receivers.find { |site, _| site.split(":")[-2] == line.to_s }&.last
  end

  def test_a_proc_whose_signature_names_self_is_recorded_as_a_proc
    run_runner do |runner|
      assert_equal ["(::Proc | nil)"], receiver_at(runner, "def run_default")
    end
  end

  def test_a_proc_whose_signature_names_instance_is_recorded_as_a_proc
    run_runner do |runner|
      assert_equal ["::Proc"], receiver_at(runner, "def run_maker")
    end
  end

  def test_a_receiver_typed_self_is_recorded_as_the_class_the_call_is_made_in
    run_runner do |runner|
      assert_equal ["::Box"], receiver_at(runner, "def run_peer")
    end
  end

  def test_no_receiver_the_checker_typed_is_left_unrecorded
    run_runner do |runner|
      assert_empty runner.unrecorded_receivers
    end
  end
end
