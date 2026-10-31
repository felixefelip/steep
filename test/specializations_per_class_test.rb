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
end
