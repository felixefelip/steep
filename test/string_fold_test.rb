require_relative "test_helper"

# felixefelip/steep#209, item 2: the core calls an inflector rule is applied
# with, folded over a literal receiver, a literal pattern and a literal
# replacement.
class StringFoldTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  def check(source_text, literal_method_registry: Steep::Project::LiteralMethodRegistry.new)
    with_checker(with_stdlib: true) do |checker|
      source = parse_ruby(source_text)

      with_standard_construction(checker, source, literal_method_registry: literal_method_registry) do |construction, typing|
        pair = construction.synthesize(source.node)

        assert_no_error typing
        yield pair
      end
    end
  end

  def test_sub_with_a_regexp_folds
    check(<<~'RUBY') do |pair|
      # @type var word: "posts"
      word = _ = "posts"
      x = word.sub(/s\z/, "")
    RUBY
      assert_equal parse_type('"post"'), pair.context.type_env[:x]
    end
  end

  def test_sub_with_a_string_pattern_and_a_backreference_folds
    check(<<~'RUBY') do |pair|
      # @type var word: "people"
      word = _ = "people"
      x = word.sub(/(p)eople$/i, '\1erson')
    RUBY
      assert_equal parse_type('"person"'), pair.context.type_env[:x]
    end
  end

  def test_delete_suffix_folds
    check(<<~'RUBY') do |pair|
      # @type var word: "comments"
      word = _ = "comments"
      x = word.delete_suffix("s")
    RUBY
      assert_equal parse_type('"comment"'), pair.context.type_env[:x]
    end
  end

  def test_sub_with_a_replacement_hash_does_not_fold
    check(<<~'RUBY') do |pair|
      # @type var word: "posts"
      word = _ = "posts"
      x = word.sub(/s/, { "s" => "" })
    RUBY
      assert_equal parse_type("::String"), pair.context.type_env[:x]
    end
  end

  # `sub!` changes the value in place: the variable is the new literal from
  # here on, and the call answers it.
  def test_sub_bang_that_matches_sets_the_variable
    check(<<~'RUBY') do |pair|
      # @type var word: "posts"
      word = _ = "posts"
      result = word.dup
      returned = result.sub!(/s\z/, "")
      copy = result
    RUBY
      assert_equal parse_type('"post"'), pair.context.type_env[:copy]
      assert_equal parse_type('"post"'), pair.context.type_env[:returned]
      assert_equal parse_type('"posts"'), pair.context.type_env[:word]
    end
  end

  # No match: the value is as it was, and `sub!` answers nil.
  def test_sub_bang_that_does_not_match_keeps_the_variable
    check(<<~'RUBY') do |pair|
      # @type var word: "post"
      word = _ = "post"
      result = word.dup
      returned = result.sub!(/s\z/, "")
      copy = result
    RUBY
      assert_equal parse_type('"post"'), pair.context.type_env[:copy]
      assert_equal parse_type("nil"), pair.context.type_env[:returned]
    end
  end

  def test_sub_bang_over_an_operand_it_cannot_read_widens
    check(<<~'RUBY') do |pair|
      # @type var word: "posts"
      word = _ = "posts"
      # @type var pattern: Regexp
      pattern = _ = /s/
      result = word.dup
      returned = result.sub!(pattern, "")
      copy = result
    RUBY
      assert_equal parse_type("::String"), pair.context.type_env[:copy]
      assert_equal parse_type("::String?"), pair.context.type_env[:returned]
    end
  end

  def test_a_redefined_sub_bang_does_not_fold
    registry = Steep::Project::LiteralMethodRegistry.new
    registry.ingest_source(<<~'RUBY', path_name: "string_ext.rb")
      class String
        def sub!(*) = replace("x")
      end
    RUBY

    check(<<~'RUBY', literal_method_registry: registry) do |pair|
      # @type var word: "posts"
      word = _ = "posts"
      result = word.dup
      result.sub!(/s\z/, "")
      copy = result
    RUBY
      assert_equal parse_type("::String"), pair.context.type_env[:copy]
    end
  end
end
