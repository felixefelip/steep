require_relative "test_helper"
require_relative "specializations_project_helper"

class InheritedHookTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class Model
      self.@cache: Hash[String, String]?
      def self.inherited: (untyped subclass) -> untyped
      def self.cache: () -> Hash[String, String]
      def self.cached: (String name) -> String
    end
    class Post < Model
    end
  RBS

  def cached(hook)
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/class.rb", <<~RUBY)
        class Class
          private

          def inherited(subclass)
          end
        end
      RUBY
      write("app/app.rb", <<~RUBY)
        class Model
          def self.inherited(subclass)
            super
            #{hook}
          end

          def self.cache = @cache ||= {}
          def self.cached(name) = cache[name] || name
        end

        class Post < Model
          cache
        end

        Post.cached("Comment")
      RUBY
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      return Steep::Specializations::Runner.new(setup_project).run.fetch("Model.cached", {})['("Comment") on singleton(::Post)']
    end
  end

  def test_a_subclass_s_memos_start_unset_past_a_hook_that_leaves_them_alone
    assert_equal '"Comment"', cached("nil")
  end

  def test_a_hook_that_stores_into_the_subclass_s_memo_leaves_it_unknown
    assert_nil cached('subclass.cache["Comment"] = "Mine"')
  end
end
