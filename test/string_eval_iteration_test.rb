require_relative "test_helper"
require_relative "specializations_project_helper"

class StringEvalIterationTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  def test_a_writer_called_once_per_element_of_an_each_writes_once_per_element
    in_tmpdir do
      write("sig/base.rbs", <<~RBS)
        class Writer
          def self.generate: (untyped owner, Symbol name) -> void
        end

        class Base
          def self.readers: (*Symbol names) -> untyped
        end
      RBS
      write("app/base.rb", <<~RUBY)
        class Writer
          def self.generate(owner, name)
            owner.class_eval "def \#{name}; 1; end"
          end
        end

        class Base
          def self.readers(*names)
            names.each { |name| Writer.generate(self, name) }
          end

          readers :size, :weight
        end
      RUBY

      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run

      assert_equal ["def size; 1; end", "def weight; 1; end"], runner.evals.fetch("app/base.rb:12:2").map { |chunk| chunk&.source }
    end
  end
end
