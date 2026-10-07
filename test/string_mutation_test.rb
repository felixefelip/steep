require_relative "test_helper"

# felixefelip/steep#207. A literal type names the VALUE a string holds, and a
# call that may change that value in place makes the name a lie from then on.
class StringMutationTest < Minitest::Test
  include TestHelper
  include TypeErrorAssertions
  include FactoryHelper
  include SubtypingHelper
  include TypeConstructionHelper

  def check(source_text, signatures = {})
    with_checker(signatures, with_stdlib: true) do |checker|
      source = parse_ruby(source_text)

      with_standard_construction(checker, source) do |construction, typing|
        pair = construction.synthesize(source.node)

        assert_no_error typing
        yield pair, typing, source
      end
    end
  end

  def test_a_mutation_widens_the_local_it_was_called_on
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts"
      word = _ = "posts"
      result = word.dup
      stripped = result.sub!(/s\z/, "")
      copy = result
    RUBY
      assert_equal parse_type('"posts"'), pair.context.type_env[:word]
      assert_equal parse_type("::String"), pair.context.type_env[:copy]
      # `sub!` answers its receiver, and that receiver is no longer "posts".
      assert_equal parse_type("::String?"), pair.context.type_env[:stripped]
    end
  end

  def test_a_mutation_widens_every_literal_of_a_union
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts" | "comments" | nil
      word = _ = "posts"
      word << "!" if word
      copy = word
    RUBY
      assert_equal parse_type("::String?"), pair.context.type_env[:copy]
    end
  end

  def test_a_mutation_widens_the_ivar_it_was_called_on
    check(<<~'RUBY', "holder.rbs" => <<~RBS) do |_pair, typing, source|
      class Holder
        def mutate
          @name.concat("!")
          @name
        end
      end
    RUBY
      class Holder
        @name: "posts" | "comments"
        def mutate: () -> String
      end
    RBS
      read = source.node.children[2].children[2].children[1]
      assert_equal parse_type("::String"), typing.type_of(node: read)
    end
  end

  def test_a_call_that_leaves_the_value_unchanged_keeps_the_literal
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts" | "comments"
      word = _ = "posts"
      word.end_with?("s")
      word.length
      word == "posts"
      word.frozen?
      word.upcase
      copy = word
    RUBY
      assert_equal parse_type('"posts" | "comments"'), pair.context.type_env[:copy]
    end
  end

  # A block can reach the receiver through the local it closes over, and what
  # it does there is not this call's to vouch for.
  def test_a_call_with_a_block_widens
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts"
      word = _ = "posts"
      word.each_char { |c| c }
      copy = word
    RUBY
      assert_equal parse_type("::String"), pair.context.type_env[:copy]
    end
  end

  # `ActiveSupport::Inflector.apply_inflections`, less the `break` (whose own
  # diagnostic is beside the point): the mutation is inside the block, and a
  # block's body is checked with the outer locals pinned — so what it narrows
  # there never comes back out on its own.
  def test_a_mutation_inside_a_block_widens_the_outer_local
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts"
      word = _ = "posts"
      # @type var rules: Array[[Regexp, String]]
      rules = _ = []
      result = word.dup
      rules.each { |(rule, replacement)| result.sub!(rule, replacement) }
      copy = result
    RUBY
      assert_equal parse_type('"posts"'), pair.context.type_env[:word]
      assert_equal parse_type("::String"), pair.context.type_env[:copy]
    end
  end

  def test_a_mutation_in_a_nested_block_widens_the_outer_local
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts"
      word = _ = "posts"
      [1].each { [2].each { word << "!" } }
      copy = word
    RUBY
      assert_equal parse_type("::String"), pair.context.type_env[:copy]
    end
  end

  def test_a_mutation_inside_a_block_widens_the_ivar
    check(<<~'RUBY', "holder.rbs" => <<~RBS) do |_pair, typing, source|
      class Holder
        def mutate
          [1].each { @name.concat("!") }
          @name
        end
      end
    RUBY
      class Holder
        @name: "posts" | "comments"
        def mutate: () -> String
      end
    RBS
      read = source.node.children[2].children[2].children[1]
      assert_equal parse_type("::String"), typing.type_of(node: read)
    end
  end

  # The block's own parameter is another variable, whatever its name.
  def test_a_block_parameter_of_the_same_name_is_not_the_outer_local
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts"
      word = _ = "posts"
      ["a"].each { |word| word << "!" }
      copy = word
    RUBY
      assert_equal parse_type('"posts"'), pair.context.type_env[:copy]
    end
  end

  def test_a_read_inside_a_block_keeps_the_literal
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts"
      word = _ = "posts"
      [1].each { word.end_with?("s") }
      copy = word
    RUBY
      assert_equal parse_type('"posts"'), pair.context.type_env[:copy]
    end
  end

  def test_a_mutation_inside_a_loop_widens_the_outer_local
    check(<<~'RUBY') do |pair, _typing, _source|
      # @type var word: "posts"
      word = _ = "posts"
      # @type var flag: bool
      flag = _ = true
      while flag
        word.sub!(/s\z/, "")
        flag = false
      end
      copy = word
    RUBY
      assert_equal parse_type("::String"), pair.context.type_env[:copy]
    end
  end

  # A project that redefines one of them writes what the program runs instead.
  def test_a_redefined_method_is_not_vouched_for
    with_checker(with_stdlib: true) do |checker|
      source = parse_ruby(<<~'RUBY')
        # @type var word: "posts"
        word = _ = "posts"
        word.end_with?("s")
        copy = word
      RUBY

      registry = Steep::Project::LiteralMethodRegistry.new
      registry.ingest_source(<<~'RUBY', path_name: "string_ext.rb")
        class String
          def end_with?(*) = replace("")
        end
      RUBY

      with_standard_construction(checker, source, literal_method_registry: registry) do |construction, typing|
        pair = construction.synthesize(source.node)

        assert_no_error typing
        assert_equal parse_type("::String"), pair.context.type_env[:copy]
      end
    end
  end
end
