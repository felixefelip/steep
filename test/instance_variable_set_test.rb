require_relative "test_helper"
require_relative "specializations_project_helper"

class InstanceVariableSetTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class Model
      self.@cache: Hash[String, String]
      def self.inherited: (untyped subclass) -> untyped
      def self.cached: (String name) -> String
      def self.store: (String name) -> String
      def self.reset: () -> Hash[String, String]
    end
    class Post < Model
    end
  RBS

  def cached(post_body: "", model_body: "")
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", <<~RUBY)
        class Model
          def self.inherited(subclass)
            super
            subclass.instance_variable_set(:@cache, {})
          end

          def self.cached(name) = @cache[name] || name
          def self.store(name) = (@cache[name] = "Stored")
          #{model_body}
        end

        class Post < Model
          #{post_body}
        end

        Post.cached("Comment")
      RUBY
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      answers = Steep::Specializations::Runner.new(setup_project).run.fetch("Model.cached", {})
      return answers.find { |key, _| key.start_with?('("Comment") on singleton(::Post)') }&.last
    end
  end

  def test_a_hash_an_inherited_hook_sets_on_the_subclass_is_what_the_subclass_holds
    assert_equal '"Comment"', cached
  end

  def test_a_store_into_that_hash_leaves_it_unknown
    assert_nil cached(post_body: 'store("Comment")')
  end

  def test_a_method_that_may_rewrite_the_ivar_leaves_it_unknown
    assert_nil cached(model_body: 'def self.reset = (@cache = { "Comment" => "Reset" })')
  end
end
