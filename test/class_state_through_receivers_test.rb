require_relative "test_helper"
require_relative "specializations_project_helper"

class ClassStateThroughReceiversTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  DEFINITIONS = <<~'RUBY'
    class Rules
      attr_reader :singulars

      def initialize
        @singulars = []
      end

      def singular(rule, replacement)
        @singulars.prepend([rule, replacement])
      end
    end

    class Holder
      def self.instances = @instances ||= {}
      def self.instance(locale = :en) = (instances[locale] ||= Rules.new)

      def self.singularize(word)
        result = word.dup
        instance(:en).singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
        result
      end

      instance(:en).singular(/s\z/, "")
    end

    class String
      def sing = Holder.singularize(self)
    end
  RUBY

  RBS = <<~RBS
    class Rules
      attr_reader singulars: Array[untyped]
      def initialize: () -> Array[untyped]
      def singular: (untyped rule, untyped replacement) -> Array[untyped]
    end
    class Holder
      self.@instances: Hash[Symbol, Rules]?
      def self.instances: () -> Hash[Symbol, Rules]
      def self.instance: (?Symbol locale) -> Rules
      def self.singularize: (String word) -> String
    end
    class String
      def sing: () -> String
      def poison: () -> untyped
    end
    class Builder
      def self.build: (untyped model, Symbol name) -> untyped
      def self.readers: (untyped model, Symbol name) -> untyped
    end
    class Base
      def self.build: (untyped model, Symbol name) -> untyped
      def self.readers: (untyped model, Symbol name) -> untyped
    end
    class Coll < Base
      def self.readers: (untyped model, Symbol name) -> untyped
    end
    class Many < Coll
    end
    module Macros
      def records: (untyped model, Symbol name) -> untyped
    end
    class Extended
      extend Macros
    end
    class Wrapper
      def self.wrap: (String word) -> String
    end
    class Post
      def self.m: (Symbol name) -> untyped
      def self.via: (Symbol name, singleton(Wrapper) wrapper) -> untyped
      def self.has: (Symbol name) -> untyped
      def self.adopt: (Symbol name) -> untyped
    end
  RBS

  def chunks(ruby)
    in_tmpdir do
      write("sig/app.rbs", RBS)
      write("app/app.rb", DEFINITIONS + ruby)
      postconditions = Steep::Postconditions::Runner.new(setup_project)
      postconditions.write(postconditions.run)
      runner = Steep::Specializations::Runner.new(setup_project)
      runner.run
      runner.evals.values.flatten.map { |chunk| chunk&.source }
    end
  end

  def test_a_macro_reads_a_class_state_through_a_call_on_a_string
    assert_equal ["def post_ids; []; end"], chunks(<<~'RUBY')
      class Post
        def self.m(name) = class_eval("def #{name.to_s.sing}_ids; []; end")
        m :posts
      end
    RUBY
  end

  def test_a_builder_chain_hands_the_class_state_on_to_a_call_on_a_string
    assert_equal ["def post_ids; []; end"], chunks(<<~'RUBY')
      class Builder
        def self.build(model, name) = readers(model, name)
        def self.readers(model, name) = model.class_eval("def #{name.to_s.sing}_ids; []; end")
      end

      class Post
        Builder.build(self, :posts)
      end
    RUBY
  end

  def test_a_macro_reads_a_class_state_through_a_class_method_called_on_an_argument
    assert_equal ["def post_ids; []; end"], chunks(<<~'RUBY')
      class Wrapper
        def self.wrap(word) = Holder.singularize(word)
      end

      class Post
        def self.via(name, wrapper) = class_eval("def #{wrapper.wrap(name.to_s)}_ids; []; end")
        via :posts, Wrapper
      end
    RUBY
  end

  def test_a_call_on_self_reads_the_class_state_in_the_override_a_subclass_runs
    assert_equal ["def post_ids; []; end"], chunks(<<~'RUBY')
      class Base
        def self.build(model, name) = readers(model, name)
        def self.readers(model, name) = nil
      end

      class Coll < Base
        def self.readers(model, name) = model.class_eval("def #{name.to_s.sing}_ids; []; end")
      end

      class Many < Coll
      end

      class Post
        Many.build(self, :posts)
      end
    RUBY
  end

  def test_a_method_reads_the_class_state_through_a_class_method_a_constant_inherits
    written = chunks(<<~'RUBY')
      class Base
        def self.build(model, name) = readers(model, name)
        def self.readers(model, name) = nil
      end

      class Coll < Base
        def self.readers(model, name) = model.class_eval("def #{name.to_s.sing}_ids; []; end")
      end

      class Many < Coll
      end

      class Post
        def self.has(name) = Many.build(self, name)
        has :posts
      end
    RUBY

    assert_includes written, "def post_ids; []; end"
  end

  def test_a_method_reads_the_class_state_through_a_module_a_constant_extends
    written = chunks(<<~'RUBY')
      module Macros
        def records(model, name) = model.class_eval("def #{name.to_s.sing}_ids; []; end")
      end

      class Extended
        extend Macros
      end

      class Post
        def self.adopt(name) = Extended.records(self, name)
        adopt :posts
      end
    RUBY

    assert_includes written, "def post_ids; []; end"
  end

  def test_declines_a_class_state_a_call_on_a_string_may_write
    assert_equal [nil], chunks(<<~'RUBY')
      class String
        def poison = Holder.instance(:en).singular(/ts\z/, "")
      end

      class Post
        def self.m(name)
          name.to_s.poison
          class_eval("def #{name.to_s.sing}_ids; []; end")
        end
        m :posts
      end
    RUBY
  end
end
