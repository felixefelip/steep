require_relative "test_helper"
require_relative "specializations_project_helper"

# A call that writes a block is specialized under what that block returns, so
# a body that answers what it yields answers it for this call
# (felixefelip/rbs_infer#535).
class SpecializationsBlockReturnTest < Minitest::Test
  include TestHelper
  include ShellHelper
  include SpecializationsProjectHelper

  Specializations = Steep::Specializations

  def specialize(project, generations: 3)
    generations.times do
      runner = Specializations::Runner.new(project)
      runner.write(runner.run)
      project.reload_specializations!
    end
  end

  def test_a_call_with_a_block_returns_what_the_body_makes_of_the_block_return
    in_tmpdir do
      write("sig/bag.rbs", <<~RBS)
        class Bag
          def twice: () { (Integer) -> untyped } -> untyped
        end
        class Caller
          def call: () -> untyped
        end
      RBS
      write("app/bag.rb", <<~RUBY)
        class Bag
          def twice = yield(1) + yield(2)
        end

        class Caller
          def call
            three = 3
            Bag.new.twice { |n| three }
          end
        end
      RUBY
      project = setup_project
      specialize(project)

      assert_equal({ "() &-> ::Integer" => "::Integer" }, Specializations::Runner.new(project).run.fetch("Bag#twice"))
      assert_equal "::Integer", body_types(project, current_dir + "app/bag.rb").fetch("call")
    end
  end

  def test_a_body_that_only_hands_its_block_on_answers_for_any_block
    in_tmpdir do
      write("sig/attr.rbs", <<~RBS)
        module Attr
          def self.redefine_method: (Module owner, Symbol name) { () -> untyped } -> Symbol
        end
        class Widget
          def first: () -> untyped
          def second: () -> untyped
          def one: () -> untyped
          def label: () -> untyped
        end
      RBS
      write("app/attr.rb", <<~RUBY)
        module Attr
          def self.redefine_method(owner, name, &block)
            owner.define_method(name, &block)
            name
          end
        end

        class Widget
          def first = Attr.redefine_method(Widget, :size) { one }
          def second = Attr.redefine_method(Widget, :size) { label }
          def one = 1
          def label = "one"
        end
      RUBY
      project = setup_project
      specialize(project)

      assert_equal({ "(singleton(::Widget), :size) &-> untyped" => ":size" }, Specializations::Runner.new(project).run.fetch("Attr.redefine_method"))
      assert_equal %w[:size :size], body_types(project, current_dir + "app/attr.rb").values_at("first", "second")
    end
  end

  def test_a_body_that_hands_its_block_to_a_method_returning_its_value_keeps_the_block_return
    in_tmpdir do
      write("sig/bag.rbs", <<~RBS)
        class Bag
          def mapped: () { (Integer) -> untyped } -> untyped
        end
        class Caller
          def call: () -> untyped
          def label: () -> String
        end
      RBS
      write("app/bag.rb", <<~RUBY)
        class Bag
          def mapped(&block) = [1].map(&block)
        end

        class Caller
          def call = Bag.new.mapped { |n| label }
          def label = "x"
        end
      RUBY
      project = setup_project
      specialize(project)

      assert_equal ["() &-> ::String"], Specializations::Runner.new(project).run.fetch("Bag#mapped").keys
    end
  end

  def test_a_body_handing_its_block_on_reads_it_where_the_body_it_reaches_does
    in_tmpdir do
      write("sig/bag.rbs", <<~RBS)
        class Bag
          def each_one: () { (Integer) -> untyped } -> untyped
          def stored: () { () -> untyped } -> untyped
        end
        class SubBag < Bag
          def each_one: () { (Integer) -> untyped } -> untyped
          def named: (Symbol name) { () -> untyped } -> untyped
          def chained: (Symbol name) { () -> untyped } -> untyped
          def kept: () { () -> untyped } -> untyped
        end
      RBS
      write("app/bag.rb", <<~RUBY)
        class Bag
          def each_one = yield(1)
          def stored(&block) = @block = block
        end

        class SubBag < Bag
          def each_one
            super
          end

          def named(name, &block) = self.class.define_method(name, &block)
          def chained(name, &) = named(name, &)
          def kept(&block) = stored(&block)
        end
      RUBY
      project = setup_project
      typing = checked(project, current_dir + "app/bag.rb")
      facts = Specializations::BlockReads.facts(typing, Specializations::Collector.definitions(typing.source))

      assert_equal %w[SubBag#chained SubBag#named], Specializations::BlockReads.unread(facts).sort
    end
  end

  def test_a_block_returning_a_type_variable_of_its_caller_keys_nothing
    in_tmpdir do
      write("sig/box.rbs", <<~RBS)
        class Box[T]
          def item: () -> T
          def run: () { () -> untyped } -> untyped
          def via: () -> untyped
        end
      RBS
      write("app/box.rb", <<~RUBY)
        class Box
          def item = @item
          def run = yield
          def via = run { item }
        end
      RUBY

      assert_nil Specializations::Runner.new(setup_project).run["Box#run"]
    end
  end

  def test_a_core_method_written_in_ruby_answers_for_the_block_its_call_writes
    in_tmpdir do
      write("sig/shapes.rbs", <<~RBS)
        class Circle
          def area: ((5 | 2) scale) -> (15 | 6)
        end
        class Square
          def area: ((5 | 2) scale) -> (20 | 8)
        end
        class Caller
          def total: () -> untyped
        end
      RBS
      write("app/array.rb", <<~RUBY)
        class Array
          def sum(init = 0)
            value = init
            index = 0
            while index < length
              element = self[index]
              element = yield(element) if block_given?
              value += element
              index += 1
            end
            value
          end
        end
      RUBY
      write("app/shapes.rb", <<~RUBY)
        class Caller
          def total
            shapes = [Circle.new, Square.new]
            shapes.sum { |shape| shape.area(2) }
          end
        end
      RUBY
      project = setup_project
      specialize(project)

      assert_equal "::Integer", body_types(project, current_dir + "app/shapes.rb").fetch("total")
    end
  end
end
