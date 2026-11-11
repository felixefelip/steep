require_relative "test_helper"
require_relative "specializations_project_helper"

# A body checked once per class it runs on or is handed, so a call reads the
# return of the subclass's override it reaches (felixefelip/rbs_infer#524).
class SpecializationsPerClassTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Specializations = Steep::Specializations

  ANIMALS_RBS = <<~RBS
    class Animal
      def introduce: () -> untyped
    end
    class Dog < Animal
      def speak: (String greeting) -> "woof"
    end
    class Cat < Animal
      def speak: (String greeting) -> "meow"
    end
  RBS

  ANIMALS_RUBY = <<~RUBY
    class Animal
      def introduce
        speak("hello")
      end
    end

    class Dog < Animal
      def speak(greeting)
        "woof"
      end
    end

    class Cat < Animal
      def speak(greeting)
        "meow"
      end
    end
  RUBY

  def test_runner_checks_an_inherited_instance_method_on_the_subclass_whose_override_it_calls
    in_tmpdir do
      write("sig/animals.rbs", ANIMALS_RBS + "class Caller\n  def dog: () -> untyped\n  def cat: () -> untyped\nend\n")
      write("app/animals.rb", ANIMALS_RUBY + <<~RUBY)
        class Caller
          def dog = Dog.new.introduce
          def cat = Cat.new.introduce
        end
      RUBY
      project = setup_project
      runner = Specializations::Runner.new(project)
      methods = runner.run

      assert_equal({ "() on ::Dog" => '"woof"', "() on ::Cat" => '"meow"' }, methods.fetch("Animal#introduce"))

      runner.write(methods)
      project.reload_specializations!
      types = body_types(project, current_dir + "app/animals.rb")

      assert_equal '"woof"', types.fetch("dog")
      assert_equal '"meow"', types.fetch("cat")
    end
  end

  def test_runner_keys_an_inherited_instance_method_by_a_class_whose_subclass_overrides_what_it_calls_only_where_built_as_it
    in_tmpdir do
      write("sig/animals.rbs", ANIMALS_RBS + "class Puppy < Dog\n  def speak: (String greeting) -> \"yip\"\nend\nclass Caller\n  def any: (Dog dog) -> untyped\n  def built: () -> untyped\nend\n")
      write("app/animals.rb", ANIMALS_RUBY + <<~RUBY)
        class Puppy < Dog
          def speak(greeting)
            "yip"
          end
        end

        class Caller
          def any(dog) = dog.introduce
          def built = Dog.new.introduce
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "() on ::Dog" => '"woof"' }, methods["Animal#introduce"])
    end
  end

  def test_runner_specializes_an_argument_of_a_class_narrower_than_its_parameter
    in_tmpdir do
      write("sig/leaf.rbs", <<~RBS)
        class Leaf
          def accept: (Counter | Printer visitor) -> untyped
        end
        class Counter
          def visit_leaf: (Leaf leaf) -> 1
        end
        class Printer
          def visit_leaf: (Leaf leaf) -> "leaf"
        end
      RBS
      write("app/leaf.rb", <<~RUBY)
        class Leaf
          def accept(visitor)
            visitor.visit_leaf(self)
          end
        end

        class Counter
          def visit_leaf(leaf) = 1
        end

        class Printer
          def visit_leaf(leaf) = "leaf"
        end

        Leaf.new.accept(Counter.new)
        Leaf.new.accept(Printer.new)
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(::Counter)" => "1", "(::Printer)" => '"leaf"' }, methods.fetch("Leaf#accept"))
    end
  end

  def test_an_assignment_to_a_setter_reads_the_value_assigned
    in_tmpdir do
      write("sig/box.rbs", <<~RBS)
        class Item
          def label: () -> "item"
        end
        class Box
          def item=: (Item? item) -> untyped
          def fill: () -> untyped
        end
      RBS
      write("app/box.rb", <<~RUBY)
        class Item
          def label = "item"
        end

        class Box
          def item=(item)
            item&.label
          end

          def fill
            self.item = Item.new
          end
        end
      RUBY
      project = setup_project
      runner = Specializations::Runner.new(project)
      methods = runner.run

      assert_equal({ "(::Item)" => '"item"' }, methods.fetch("Box#item="))

      runner.write(methods)
      project.reload_specializations!

      assert_equal "::Item", body_types(project, current_dir + "app/box.rb").fetch("fill")
    end
  end

  def test_runner_keys_a_self_handed_down_two_calls_as_the_class_that_handed_it
    in_tmpdir do
      write("sig/app.rbs", <<~RBS)
        class Post
          def self.has_many: (Symbol name) -> untyped
        end
        class Builder
          def self.build: (untyped model, Symbol name) -> untyped
          def self.create: (untyped model, Symbol name) -> untyped
          def self.macro: () -> Symbol
        end
        class HasMany < Builder
          def self.macro: () -> Symbol
        end
      RBS
      write("app/app.rb", <<~RUBY)
        class Builder
          def self.build(model, name)
            macro
            create(model, name)
          end

          def self.create(model, name)
            model
          end

          def self.macro = :base
        end

        class HasMany < Builder
          def self.macro = :has_many
        end

        class Post
          def self.has_many(name)
            HasMany.build(self, name)
          end

          has_many :comments
        end
      RUBY

      methods = Specializations::Runner.run(setup_project)

      assert_equal({ "(singleton(::Post), :comments)" => "singleton(::Post)", "(self, :comments)" => "self" }, methods.fetch("Builder.create"))
      assert_equal({ "(:comments) on singleton(::Post)" => "singleton(::Post)", "(:comments)" => "self" }, methods.fetch("Post.has_many"))
    end
  end

  LITERAL_RECEIVER_RBS = <<~RBS
    class String
      def shout: () -> String
      def forwarded: (?Symbol locale) -> String
      def tagged: (Symbol tag) -> Symbol
      def growing: () -> String
      def outer: () -> String
      def inner: () -> String
    end
    module Ops
      def self.up: (String text, ?Symbol locale) -> String
    end
    class Caller
      def written: () -> untyped
      def forwarding: () -> untyped
      def from_symbol: (Symbol name) -> untyped
      def symbol: () -> untyped
      def unobserved: () -> untyped
      def grows: () -> untyped
      def through_self: () -> untyped
      def relay: (String text) -> untyped
      def long: () -> untyped
    end
    class Macro
      def self.macro: (Symbol name) -> untyped
    end
  RBS

  LITERAL_RECEIVER_RUBY = <<~'RUBY'
    module Ops
      def self.up(text, locale = :en) = text.upcase
    end

    class String
      def shout = upcase
      def forwarded(locale = :en) = Ops.up(self, locale)
      def tagged(tag) = tag
      def outer = inner
      def inner = upcase
      def growing
        (self + "x").growing
        upcase
      end
    end

    class Caller
      def written = "abc".shout
      def forwarding = "abc".forwarded
      def from_symbol(name) = name.to_s.shout
      def symbol = from_symbol(:abc)
      def unobserved = "abc".tagged(:x)
      def grows = "abc".growing
      def through_self = "abc".outer
      def relay(text) = text.shout
      def long = relay("%{long}")
    end

    class Macro
      def self.macro(name) = class_eval("def #{name.to_s.shout}; end")
      macro :abc
    end
  RUBY

  def literal_receiver_project
    write("sig/literal_receiver.rbs", LITERAL_RECEIVER_RBS)
    long = "a" * (Specializations::Runner::LITERAL_WIDTH + 1)
    write("app/literal_receiver.rb", LITERAL_RECEIVER_RUBY.sub("%{long}", long))
    setup_project
  end

  def test_runner_specializes_a_method_by_its_literal_receiver
    in_tmpdir do
      project = literal_receiver_project
      runner = Specializations::Runner.new(project)
      methods = runner.run

      assert_equal '"ABC"', methods.fetch("String#shout").fetch('() on "abc"')
      assert_equal '"ABC"', methods.fetch("String#forwarded").fetch('() on "abc"')
      assert_equal '"ABC"', methods.fetch("Caller#from_symbol").fetch("(:abc)")
      assert_equal '"ABC"', methods.fetch("String#inner").fetch('() on "abc"')
      assert_equal(["def ABC; end"], runner.evals.values.flatten.map { |chunk| chunk&.source })

      runner.write(methods)
      project.reload_specializations!
      types = body_types(project, current_dir + "app/literal_receiver.rb")

      assert_equal '"ABC"', types.fetch("written")
      assert_equal '"ABC"', types.fetch("forwarding")
      assert_equal '"ABC"', types.fetch("symbol")
    end
  end

  def test_runner_keys_no_literal_receiver_a_body_does_not_observe
    in_tmpdir do
      methods = Specializations::Runner.run(literal_receiver_project)

      assert_equal({ "(:x)" => ":x" }, methods.fetch("String#tagged"))
    end
  end

  def test_runner_widens_a_literal_receiver_that_keeps_growing
    in_tmpdir do
      methods = Specializations::Runner.run(literal_receiver_project)

      tuples = methods.fetch("String#growing")

      assert_includes tuples.keys, '() on "abc"'
      assert_operator tuples.size, :<=, Specializations::Runner::WIDEN_AFTER + 1
    end
  end

  def test_runner_widens_a_literal_receiver_past_the_width
    in_tmpdir do
      methods = Specializations::Runner.run(literal_receiver_project)

      assert_equal ['() on "abc"'], methods.fetch("String#shout").keys.grep(/ on /)
    end
  end

  def test_runner_runs_a_macro_on_its_literal_receiver
    in_tmpdir do
      write("sig/literal_macro.rbs", <<~RBS)
        class String
          def define_it: () -> untyped
        end
        class Host
        end
      RBS
      write("app/literal_macro.rb", <<~'RUBY')
        class String
          def define_it = Host.class_eval("def #{upcase}; end")
        end

        class Host
          "abc".define_it
        end
      RUBY
      runner = Specializations::Runner.new(setup_project)
      runner.run

      assert_includes runner.evals.values.flatten.map { |chunk| chunk&.source }, "def ABC; end"
    end
  end
end
