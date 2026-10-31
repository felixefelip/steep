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

  def test_sub_with_an_interpolated_regexp_of_literals_folds
    check(<<~'RUBY') do |pair|
      # @type var word: "people"
      word = _ = "people"
      # @type var head: "p"
      head = _ = "p"
      x = word.sub(/(#{head})#{"eople"}$/i, '\1erson')
    RUBY
      assert_equal parse_type('"person"'), pair.context.type_env[:x]
    end
  end

  def test_sub_with_a_regexp_interpolating_a_union_folds_each_pattern
    check(<<~'RUBY') do |pair|
      # @type var word: "posts"
      word = _ = "posts"
      # @type var suffix: "s" | "ts"
      suffix = _ = "s"
      x = word.sub(/#{suffix}\z/, "")
    RUBY
      assert_equal parse_type('"post" | "pos"'), pair.context.type_env[:x]
    end
  end

  def test_sub_with_a_regexp_interpolating_a_string_does_not_fold
    check(<<~'RUBY') do |pair|
      # @type var word: "posts"
      word = _ = "posts"
      # @type var suffix: String
      suffix = _ = "s"
      x = word.sub(/#{suffix}\z/, "")
    RUBY
      assert_equal parse_type('::String'), pair.context.type_env[:x]
    end
  end

  def test_slice_by_position_folds
    check(<<~'RUBY') do |pair|
      # @type var word: "person"
      word = _ = "person"
      head = word[0]
      rest = word[1..-1]
      middle = word[1, 2]
      open = word[2..]
      before = word[...2]
      past = word[10]
    RUBY
      assert_equal parse_type('"p"'), pair.context.type_env[:head]
      assert_equal parse_type('"erson"'), pair.context.type_env[:rest]
      assert_equal parse_type('"er"'), pair.context.type_env[:middle]
      assert_equal parse_type('"rson"'), pair.context.type_env[:open]
      assert_equal parse_type('"pe"'), pair.context.type_env[:before]
      assert_equal parse_type('nil'), pair.context.type_env[:past]
    end
  end

  def test_slice_by_a_search_does_not_fold
    check(<<~'RUBY') do |pair|
      # @type var word: "person"
      word = _ = "person"
      x = word["er"]
    RUBY
      assert_equal parse_type('::String?'), pair.context.type_env[:x]
    end
  end

  def test_equality_of_two_strings_folds
    check(<<~'RUBY') do |pair|
      # @type var word: "person"
      word = _ = "person"
      head = word[0]
      x = head.upcase == "P"
      y = head == "q"
    RUBY
      assert_equal parse_type('true'), pair.context.type_env[:x]
      assert_equal parse_type('false'), pair.context.type_env[:y]
    end
  end

  def test_equality_that_is_not_decided_keeps_narrowing_the_receiver
    check(<<~'RUBY') do |pair|
      # @type var word: "a" | "b"
      word = _ = "a"
      x = word == "a" ? word : nil
    RUBY
      assert_equal parse_type('"a" | nil'), pair.context.type_env[:x]
    end
  end

  # `Inflections#irregular`, as Active Support writes the rule for a plural.
  def test_an_irregular_rule_folds
    check(<<~'RUBY') do |pair|
      # @type var singular: "person"
      singular = _ = "person"
      # @type var plural: "people"
      plural = _ = "people"
      srest = singular[1..-1]
      p0 = plural[0]
      prest = plural[1..-1]
      x = plural.sub(/(#{p0})#{prest}$/i, '\1' + srest)
    RUBY
      assert_equal parse_type('"person"'), pair.context.type_env[:x]
    end
  end

  def test_sub_with_a_backreference_folds
    check(<<~'RUBY') do |pair|
      # @type var word: "people"
      word = _ = "people"
      x = word.sub(/(p)eople$/i, '\1erson')
    RUBY
      assert_equal parse_type('"person"'), pair.context.type_env[:x]
    end
  end

  # `sub` takes a string pattern literally, where `match?` would compile it.
  def test_sub_with_a_string_pattern_takes_it_literally
    check(<<~'RUBY') do |pair|
      # @type var word: "abc"
      word = _ = "abc"
      x = word.sub(".", "")
      y = word.sub("b", "")
    RUBY
      assert_equal parse_type('"abc"'), pair.context.type_env[:x]
      assert_equal parse_type('"ac"'), pair.context.type_env[:y]
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

  def test_tr_folds
    check(<<~'RUBY') do |pair|
      # @type var code: "def a\n  1\nend"
      code = _ = "def a\n  1\nend"
      x = code.tr("\n", ";")
    RUBY
      assert_equal parse_type('"def a;  1;end"'), pair.context.type_env[:x]
    end
  end

  def test_tr_with_an_argument_that_is_not_a_literal_does_not_fold
    check(<<~'RUBY') do |pair|
      # @type var code: "def a\nend"
      code = _ = "def a\nend"
      # @type var separator: String
      separator = _ = ";"
      x = code.tr("\n", separator)
    RUBY
      assert_equal parse_type("::String"), pair.context.type_env[:x]
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

  # The review case on felixefelip/steep#215: there is no literal "." in
  # "abc", so `sub!` changes nothing and answers nil — `match?(".")`, which
  # compiles the pattern, would have said it matched.
  def test_sub_bang_with_a_string_pattern_that_does_not_occur_answers_nil
    check(<<~'RUBY') do |pair|
      # @type var word: "abc"
      word = _ = "abc"
      result = word.dup
      returned = result.sub!(".", "")
      copy = result
    RUBY
      assert_equal parse_type("nil"), pair.context.type_env[:returned]
      assert_equal parse_type('"abc"'), pair.context.type_env[:copy]
    end
  end

  def test_sub_bang_with_a_string_pattern_that_occurs_sets_the_variable
    check(<<~'RUBY') do |pair|
      # @type var word: "posts"
      word = _ = "posts"
      result = word.dup
      returned = result.sub!("s", "")
      copy = result
    RUBY
      assert_equal parse_type('"pots"'), pair.context.type_env[:returned]
      assert_equal parse_type('"pots"'), pair.context.type_env[:copy]
    end
  end

  # Not a valid regexp, which matters only to a reader that compiles it.
  def test_sub_bang_with_a_regexp_metacharacter_as_a_string_pattern
    check(<<~'RUBY') do |pair|
      # @type var word: "abc"
      word = _ = "abc"
      result = word.dup
      returned = result.sub!("(", "")
      copy = result
    RUBY
      assert_equal parse_type("nil"), pair.context.type_env[:returned]
      assert_equal parse_type('"abc"'), pair.context.type_env[:copy]
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
