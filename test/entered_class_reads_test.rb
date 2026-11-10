require_relative "test_helper"
require_relative "specializations_project_helper"

class EnteredClassReadsTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  SIG = <<~RBS
    class Holder
      self.@rules: Array[untyped]?
      def self.rules: () -> Array[untyped]?
    end
    module Plain
      def self.take: (untyped) -> void
    end
    module Reads
    end
    module Hands
    end
  RBS

  SOURCES = {
    "plain.rb" => "module Plain\n  [1].map { |x| x + 1 }\nend\n",
    "reads.rb" => "module Reads\n  Holder.rules\nend\n",
    "hands.rb" => "module Hands\n  Plain.take(Holder)\nend\n"
  }.freeze

  HOLDER = ::RBS::TypeName.parse("::Holder")

  def store(path, states, reads = nil)
    Steep::Specializations::Store.new(methods: {}, source: nil, receivers: {}, bodies: {}, entering: { path => states }, reads: reads)
  end

  # Whether the check of each file, made entering with `before`, still holds
  # entering with `after`.
  def still_holds(before, after)
    in_tmpdir do
      write("sig/app.rbs", SIG)
      paths = SOURCES.to_h { |name, content| [name, write("app/#{name}", content)] }
      project = setup_project
      paths.transform_values do |path|
        reads = Steep::Specializations::Reads.new
        checked(project, path, specializations: store(path, before, reads))
        reads.same?(store(path, after))
      end
    end
  end

  def test_a_check_holds_for_a_class_it_never_reads_whatever_that_class_enters_with
    held = still_holds({ HOLDER => { "@rules": Steep::AST::Builtin.nil_type } }, { HOLDER => { "@rules": Steep::AST::Types::Tuple.new(types: []) } })

    assert_equal({ "plain.rb" => true, "reads.rb" => false, "hands.rb" => false }, held)
  end

  def test_a_check_that_would_read_a_class_does_not_hold_once_the_class_enters
    held = still_holds({}, { HOLDER => { "@rules": Steep::AST::Builtin.nil_type } })

    assert_equal({ "plain.rb" => true, "reads.rb" => false, "hands.rb" => false }, held)
  end
end
