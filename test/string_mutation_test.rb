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
