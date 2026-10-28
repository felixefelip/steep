require_relative "test_helper"

# Unit tests for the source-walking part of the constructor reader→parameter
# binding pipeline (felixefelip/steep#60). The analyzer only recognizes shapes;
# the `.new`-site translation happens in `TypeConstruction` and is covered by
# integration tests.
class ConstructorBindingAnalyzerTest < Minitest::Test
  ConstructorBindingAnalyzer = Steep::TypeInference::ConstructorBindingAnalyzer

  def parse(source)
    parser = Steep::Source.new_parser
    buffer = ::Parser::Source::Buffer.new("<test>")
    buffer.source = source
    parser.parse(buffer)
  end

  def analyze(source)
    ConstructorBindingAnalyzer.analyze(parse(source))
  end

  def test_maps_reader_to_its_constructor_parameter_index
    result = analyze(<<~RUBY)
      class Proxy
        def initialize(klass, owner)
          @owner = owner
        end

        def owner
          @owner
        end
      end
    RUBY

    assert_equal({ "Proxy" => { owner: 1 } }, result)
  end

  def test_handles_endless_reader_and_nested_class_names
    result = analyze(<<~RUBY)
      module Post_Assignment
        class ActiveRecord_Associations_CollectionProxy
          def initialize(klass, owner)
            @owner = owner
          end

          def owner = @owner
        end
      end
    RUBY

    assert_equal(
      { "Post_Assignment::ActiveRecord_Associations_CollectionProxy" => { owner: 1 } },
      result
    )
  end

  def test_maps_multiple_readers
    result = analyze(<<~RUBY)
      class Pair
        def initialize(left, right)
          @left = left
          @right = right
        end

        def left = @left
        def right = @right
      end
    RUBY

    assert_equal({ "Pair" => { left: 0, right: 1 } }, result)
  end

  def test_ignores_reader_whose_ivar_is_not_a_constructor_parameter
    # `@name` is not assigned from a parameter, so `name` has no binding.
    result = analyze(<<~RUBY)
      class Thing
        def initialize(owner)
          @owner = owner
          @name = "x"
        end

        def owner = @owner
        def name = @name
      end
    RUBY

    assert_equal({ "Thing" => { owner: 0 } }, result)
  end

  def test_ignores_computed_reader
    # A reader whose body is not exactly `@ivar` is not a stable projection of
    # the constructor argument, so it must not be mapped.
    result = analyze(<<~RUBY)
      class Thing
        def initialize(owner)
          @owner = owner
        end

        def owner
          @owner || raise
        end
      end
    RUBY

    assert_empty result
  end

  def test_ignores_class_without_matching_binding
    result = analyze(<<~RUBY)
      class Plain
        def hello = "hi"
      end
    RUBY

    assert_empty result
  end

  def bodies(source)
    ConstructorBindingAnalyzer.scan(parse(source)).methods.fetch("Fallbacks").transform_values(&:first)
  end

  def test_a_hash_method_ending_in_super_or_a_store_under_its_key_is_a_keyed_memo
    found = bodies(<<~RUBY)
      class Fallbacks < Hash
        def [](locale)
          raise ArgumentError if locale.nil?
          locale = locale.to_sym
          super || store(locale, compute(locale))
        end

        def fetch_or(locale) = self[locale] || store(locale, [locale])
        def other_key(locale) = super || store(:en, compute(locale))
        def stored_first(locale)
          store(:en, [])
          super || store(locale, compute(locale))
        end
      end
    RUBY

    assert_equal ["(zsuper)", "(send nil :compute\n  (lvar :locale))"], found[:[]].keyed_memo.map(&:to_s)
    assert_equal ["(send\n  (self) :[]\n  (lvar :locale))", "(array\n  (lvar :locale))"], found[:fetch_or].keyed_memo.map(&:to_s)
    assert_nil found[:other_key].keyed_memo
    assert_nil found[:stored_first].keyed_memo
  end

  def test_an_element_handed_back_under_an_optional_parameter_reads_its_literal_default_where_the_call_leaves_it_out
    found = bodies(<<~RUBY)
      class Fallbacks
        def literal(locale = :en) = (@rules[locale] ||= Rules.new)
        def computed(locale = current) = @rules[locale]
        def required_after(locale = :en, scope) = @rules[locale]
      end
    RUBY

    assert_equal [:@rules, 0, true, Steep::AST::Types::Literal.new(value: :en)], found[:literal].hands_back_element
    assert_equal [:@rules, 0, false, nil], found[:computed].hands_back_element
    assert_nil found[:required_after].hands_back_element
  end

  def test_a_body_reading_a_constant_a_global_a_class_variable_or_its_class_reads_outside_state
    found = bodies(<<~RUBY)
      class Fallbacks < Hash
        def own(locale) = [locale, @default, helper(locale)]
        def constant = DEFAULT
        def global = $default
        def class_variable = @@default
        def its_class = self.class.default
      end
    RUBY

    refute found[:own].outside_state
    assert(%i[constant global class_variable its_class].all? { |name| found[name].outside_state })
  end
end
