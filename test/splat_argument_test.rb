require_relative "test_helper"
require_relative "specializations_project_helper"

# `*value` passed where its type says how many arguments it spreads into.
class SplatArgumentTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  RBS = <<~RBS
    class K
      def self.one: (String s) -> Integer
      def self.two: (String s, Integer i) -> Integer
      def self.rest: (*String s) -> Integer
      def self.optional: (?String s) -> Integer
    end
    class P
      def value: () -> untyped
      def leading: () -> untyped
      def into_rest: () -> untyped
      def none: () -> untyped
      def wrong: () -> untyped
      def tuple: () -> untyped
      def array: (Array[String] list) -> untyped
    end
  RBS

  RUBY = <<~RUBY
    class P
      def value = K.one(*"fr")
      def leading = K.two(*"fr", 1)
      def into_rest = K.rest(*"fr")
      def none = K.optional(*nil)
      def wrong = K.one(*:x)
      def tuple = K.one(*["a"])
      def array(list) = K.rest(*list)
    end
  RUBY

  def errors
    in_tmpdir do
      write("sig/p.rbs", RBS)
      write("app/p.rb", RUBY)
      typing = checked(setup_project, current_dir + "app/p.rb")
      return typing.errors.map { |error| [error.node.loc.line, error.header_line] }
    end
  end

  def test_a_value_with_no_to_a_spreads_as_itself_and_nil_as_nothing
    assert_equal [[6, "Cannot pass a value of type `::Symbol` as an argument of type `::String`"]], errors
  end
end
