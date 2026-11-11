require_relative "test_helper"

class UnrolledEachTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  def after(body, word: "categories")
    with_checker({}, with_stdlib: true) do |checker|
      source = parse_ruby(<<~RUBY)
        # @type var word: "#{word}"
        word = _ = "#{word}"
        # @type var flag: bool
        flag = _ = true
        result = word.dup
        #{body}
        after = result
      RUBY

      with_standard_construction(checker, source) do |construction, _typing|
        pair = construction.synthesize(source.node)
        return pair.context.type_env[:after].to_s
      end
    end
  end

  def test_the_first_break_taken_ends_the_call
    assert_equal '"category"', after(<<~'RUBY')
      [[/ies\z/, "y"], [/s\z/, ""]].each { |(rule, replacement)| break if result.sub!(rule, replacement) }
    RUBY
  end

  def test_a_pass_that_does_not_break_hands_its_locals_to_the_next
    assert_equal '"post"', after(<<~'RUBY', word: "posts")
      [[/ies\z/, "y"], [/s\z/, ""]].each { |(rule, replacement)| break if result.sub!(rule, replacement) }
    RUBY
    assert_equal '"category"', after(<<~'RUBY')
      [[/s\z/, ""], [/ie\z/, "y"]].each { |rule, replacement| result.sub!(rule, replacement) }
    RUBY
  end

  def test_the_locals_are_read_where_the_break_is
    assert_equal '"categorY"', after(<<~'RUBY')
      [[/ies\z/, "y"]].each do |(rule, replacement)|
        if result.sub!(rule, replacement)
          result.sub!(/y\z/, "Y")
          break
        end
      end
    RUBY
  end

  def test_a_break_inside_a_nested_block_is_that_block_s
    assert_equal '"category"', after(<<~'RUBY')
      [[/ies\z/, "y"]].each do |(rule, replacement)|
        [1].each { break }
        result.sub!(rule, replacement)
      end
    RUBY
  end

  def test_an_empty_collection_runs_no_pass
    assert_equal '"categories"', after("[].each { |rule| result.sub!(rule, '') }")
  end

  def test_declines_what_a_pass_cannot_decide
    {
      "an open condition" => '[[/s\z/, ""]].each { |(rule, replacement)| result.sub!(rule, replacement); break if flag }',
      "a break under something else" => '[[/s\z/, ""]].each { |(rule, replacement)| result.sub!(rule, replacement) && break }',
      "a next" => '[[/s\z/, ""]].each { |(rule, replacement)| next if flag; result.sub!(rule, replacement) }',
      "a collection it does not know" => "(_ = []).each { |rule| result.sub!(rule, '') }"
    }.each do |label, body|
      assert_equal "::String", after(body), label
    end
  end
end
