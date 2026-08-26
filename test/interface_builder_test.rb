require_relative "test_helper"

class InterfaceBuilderTest < Minitest::Test
  include TestHelper
  include FactoryHelper

  include Steep

  def config(**opts)
    opts = (
      {
        self_type: parse_type("::Object"),
        class_type: parse_type("singleton(::Object)"),
        instance_type: parse_type("::Object"),
        variable_bounds: {}
      }.merge(opts)
    )
    Interface::Builder::Config.new(**opts)
  end

  def test_shape__interface
    with_factory({ "a.rbs" => <<~RBS }) do
        interface _Foo[T]
          def hello: () -> [::Integer, T, self]
        end
      RBS
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("::_Foo[::String]"), config).tap do |shape|
        assert_equal parse_type("::_Foo[::String]"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, ::String, ::_Foo[::String]]")], shape.methods[:hello].method_types
      end

      builder.shape(parse_type("::_Foo[self]"), config).tap do |shape|
        assert_equal parse_type("::_Foo[self]"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, self, ::_Foo[self]]")], shape.methods[:hello].method_types
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("::_Foo[::String]"))).tap do |shape|
        assert_equal parse_type("::_Foo[::String]"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, ::String, self]")], shape.methods[:hello].method_types
      end
    end
  end

  def test_shape__class_singleton
    with_factory({ "a.rbs" => <<~RBS }) do
        class Foo
          def self.hello: () -> [::Integer, self, instance, class]
        end
      RBS
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("singleton(::Foo)"), config).tap do |shape|
        assert_equal parse_type("singleton(::Foo)"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, singleton(::Foo), ::Foo, singleton(::Foo)]")], shape.methods[:hello].method_types
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("singleton(::Foo)"))).tap do |shape|
        assert_equal parse_type("singleton(::Foo)"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, self, ::Foo, singleton(::Foo)]")], shape.methods[:hello].method_types
      end

      builder.shape(parse_type("class"), config(class_type: parse_type("singleton(::Foo)"))).tap do |shape|
        assert_equal parse_type("singleton(::Foo)"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, singleton(::Foo), ::Foo, singleton(::Foo)]")], shape.methods[:hello].method_types
      end

      builder.shape(parse_type("instance"), config(instance_type: parse_type("singleton(::Foo)"))).tap do |shape|
        assert_equal parse_type("singleton(::Foo)"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, singleton(::Foo), ::Foo, singleton(::Foo)]")], shape.methods[:hello].method_types
      end
    end
  end

  def test_shape__class_instance
    with_factory({ "a.rbs" => <<~RBS }) do
        class Foo[A, B, C]
          def hello: () -> [::Integer, A, B, C, self, instance, class]
        end
      RBS
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("::Foo[::Object, ::String, ::Integer]"), config).tap do |shape|
        assert_equal parse_type("::Foo[::Object, ::String, ::Integer]"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, ::Object, ::String, ::Integer, ::Foo[::Object, ::String, ::Integer], ::Foo[untyped, untyped, untyped], singleton(::Foo)]")], shape.methods[:hello].method_types
      end

      builder.shape(parse_type("::Foo[self, class, instance]"), config).tap do |shape|
        assert_equal parse_type("::Foo[self, class, instance]"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, self, class, instance, ::Foo[self, class, instance], ::Foo[untyped, untyped, untyped], singleton(::Foo)]")], shape.methods[:hello].method_types
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("::Foo[::Integer, ::String, ::Object]"), class_type: parse_type("singleton(::Foo)"), instance_type: parse_type("::Foo[untyped, untyped, untyped]"))).tap do |shape|
        assert_equal parse_type("::Foo[::Integer, ::String, ::Object]"), shape.type
        assert_equal [parse_method_type("() -> [::Integer, ::Integer, ::String, ::Object, self, ::Foo[untyped, untyped, untyped], singleton(::Foo)]")], shape.methods[:hello].method_types
      end
    end
  end

  def test_shape__alias
    with_factory({ "a.rbs" => <<~RBS }) do
        interface _Foo
          def itself: () -> self
        end

        type bar[T] = T
      RBS
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("::bar[::_Foo]"), config).tap do |shape|
        assert_equal parse_type("::bar[::_Foo]"), shape.type
        assert_equal [parse_method_type("() -> ::_Foo")], shape.methods[:itself].method_types
      end

      builder.shape(parse_type("::bar[self]"), config).tap do |shape|
        assert_equal parse_type("::bar[self]"), shape.type
        assert_equal [parse_method_type("() -> self")], shape.methods[:itself].method_types
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("::bar[::_Foo]"))).tap do |shape|
        assert_equal parse_type("::bar[::_Foo]"), shape.type
        assert_equal [parse_method_type("() -> ::_Foo")], shape.methods[:itself].method_types
      end
    end
  end

  def test_shape__union
    with_factory({ "a.rbs" => <<~RBS }) do
        interface _Foo
          def itself: () -> self
        end

        interface _Bar
          def itself: () -> self
        end
      RBS
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("::_Foo | ::_Bar"), config).tap do |shape|
        assert_equal parse_type("::_Foo | ::_Bar"), shape.type
        assert_equal [parse_method_type("() -> (::_Foo | ::_Bar)")], shape.methods[:itself].method_types
      end

      builder.shape(parse_type("::_Foo | self"), config(self_type: parse_type("::_Bar"))).tap do |shape|
        assert_equal parse_type("::_Foo | self"), shape.type
        assert_equal [parse_method_type("() -> (::_Foo | self)")], shape.methods[:itself].method_types
      end

      # A composite self type leaves `self` abstract, exactly as a singular one
      # does — the member hosting the method is not what `self` names.
      builder.shape(parse_type("self"), config(self_type: parse_type("::_Foo | ::_Bar"))).tap do |shape|
        assert_equal parse_type("::_Foo | ::_Bar"), shape.type
        assert_equal [parse_method_type("() -> self")], shape.methods[:itself].method_types
      end
    end
  end

  def test_shape__bool
    with_factory() do
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("bool"), config).tap do |shape|
        assert_equal parse_type("bool"), shape.type
        assert_equal [parse_method_type("() -> bool")], shape.methods[:itself].method_types
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("bool"))).tap do |shape|
        assert_equal parse_type("bool"), shape.type
        assert_equal [parse_method_type("() -> self")], shape.methods[:itself].method_types
      end
    end
  end

  def test_shape__literal
    with_factory() do
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("1"), config).tap do |shape|
        assert_equal parse_type("1"), shape.type
        assert_equal [parse_method_type("() -> 1")], shape.methods[:itself].method_types
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("1"))).tap do |shape|
        assert_equal parse_type("1"), shape.type
        assert_equal [parse_method_type("() -> self")], shape.methods[:itself].method_types
      end
    end
  end

  def test_shape__intersection
    with_factory({ "a.rbs" => <<-RBS }) do
interface _Foo
  def f: (::Integer) -> self

  def g: () -> ::String
end

interface _Bar
  def f: (::String) -> self

  def h: () -> void
end
      RBS
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("::_Foo & ::_Bar"), config).tap do |shape|
        assert_equal parse_type("::_Foo & ::_Bar"), shape.type
        assert_equal [parse_method_type("(::String) -> ::_Bar")], shape.methods[:f].method_types

        assert shape.methods[:g]
        assert shape.methods[:h]
      end

      builder.shape(parse_type("::_Foo & self"), config(self_type: parse_type("::_Bar"))).tap do |shape|
        assert_equal parse_type("::_Foo & self"), shape.type
        assert_equal [parse_method_type("(::String) -> self")], shape.methods[:f].method_types
      end

      # As with a union, an intersection self type keeps `self` abstract. This
      # is the shape a module self-type annotation takes
      # (`@type instance: Card & Card::Eventable`); substituting the hosting
      # member here made every inherited `-> self` method return that member's
      # concrete type, which then failed its own `-> self` declaration.
      builder.shape(parse_type("self"), config(self_type: parse_type("::_Foo & ::_Bar"))).tap do |shape|
        assert_equal parse_type("::_Foo & ::_Bar"), shape.type
        assert_equal [parse_method_type("(::String) -> self")], shape.methods[:f].method_types
      end
    end
  end

  def test_shape__proc
    with_factory({ "a.rbs" => <<~RBS }) do
        class BasicObject
          def special_types: () -> [self, class, instance]
        end
      RBS
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("^(::String) { (::Integer) -> void } -> ::String"), config).tap do |shape|
        assert_equal parse_type("^(::String) { (::Integer) -> void } -> ::String"), shape.type

        assert_equal(
          [parse_method_type("(::String) { (::Integer) -> void } -> ::String")],
          shape.methods[:[]].method_types
        )
        assert_equal(
          [parse_method_type("(::String) { (::Integer) -> void } -> ::String")],
          shape.methods[:call].method_types
        )

        assert_equal(
          [parse_method_type("() -> ^(::String) { (::Integer) -> void } -> ::String")],
          shape.methods[:itself].method_types
        )
      end

      builder.shape(parse_type("^(self) -> ::String"), config).tap do |shape|
        assert_equal parse_type("^(self) -> ::String"), shape.type

        assert_equal(
          [parse_method_type("(self) -> ::String")],
          shape.methods[:[]].method_types
        )
        assert_equal(
          [parse_method_type("() -> ^(self) -> ::String")],
          shape.methods[:itself].method_types
        )
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("^() -> ::String"))).tap do |shape|
        assert_equal parse_type("^() -> ::String"), shape.type

        assert_equal(
          [parse_method_type("() -> ::String")],
          shape.methods[:[]].method_types
        )
        assert_equal(
          [parse_method_type("() -> self")],
          shape.methods[:itself].method_types
        )
      end
    end
  end

  def test_shape__tuple
    with_factory() do
      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("[::Integer, top]"), config).tap do |shape|
        assert_equal parse_type("[::Integer, top]"), shape.type

        assert_includes(shape.methods[:[]].method_types, parse_method_type("(0) -> ::Integer"))
        assert_includes(shape.methods[:[]].method_types, parse_method_type("(1) -> top"))
        assert_includes(shape.methods[:[]].method_types, parse_method_type("(::int) -> top"))

        assert_includes(shape.methods[:[]=].method_types, parse_method_type("(0, ::Integer) -> ::Integer"))
        assert_includes(shape.methods[:[]=].method_types, parse_method_type("(1, top) -> top"))

        assert_includes(shape.methods[:fetch].method_types, parse_method_type("(0) -> ::Integer"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("(1) -> top"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (0, T) -> (::Integer | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (1, T) -> (top | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (0) { (::Integer) -> T } -> (::Integer | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (1) { (::Integer) -> T } -> (top | T)"))

        assert_equal([parse_method_type("() -> ::Integer")], shape.methods[:first].method_types)
        assert_equal([parse_method_type("() -> top")], shape.methods[:last].method_types)
      end

      builder.shape(parse_type("[::Integer, self]"), config).tap do |shape|
        assert_equal parse_type("[::Integer, self]"), shape.type

        assert_includes(shape.methods[:[]].method_types, parse_method_type("(0) -> ::Integer"))
        assert_includes(shape.methods[:[]].method_types, parse_method_type("(1) -> self"))

        assert_includes(shape.methods[:[]=].method_types, parse_method_type("(0, ::Integer) -> ::Integer"))
        assert_includes(shape.methods[:[]=].method_types, parse_method_type("(1, self) -> self"))

        assert_includes(shape.methods[:fetch].method_types, parse_method_type("(0) -> ::Integer"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("(1) -> self"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (0, T) -> (::Integer | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (1, T) -> (self | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (0) { (::Integer) -> T } -> (::Integer | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (1) { (::Integer) -> T } -> (self | T)"))

        assert_equal([parse_method_type("() -> ::Integer")], shape.methods[:first].method_types)
        assert_equal([parse_method_type("() -> self")], shape.methods[:last].method_types)
      end
    end
  end

  def test_shape__record
    with_factory({ "a.rbs" => <<~RBS }) do
        class BasicObject
          def special_types: () -> [self, class, instance]
        end
      RBS

      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("{ id: ::Integer, name: ::String }"), config).tap do |shape|
        shape or raise

        assert_equal parse_type("{ id: ::Integer, name: ::String }"), shape.type

        assert_includes(shape.methods[:[]].method_types, parse_method_type("(:id) -> ::Integer"))
        assert_includes(shape.methods[:[]].method_types, parse_method_type("(:name) -> ::String"))
        assert_includes(shape.methods[:[]].method_types, parse_method_type("(::Symbol) -> (::String | ::Integer | nil)"))

        assert_includes(shape.methods[:[]=].method_types, parse_method_type("(:id, ::Integer) -> ::Integer"))
        assert_includes(shape.methods[:[]=].method_types, parse_method_type("(:name, ::String) -> ::String"))

        assert_includes(shape.methods[:fetch].method_types, parse_method_type("(:id) -> ::Integer"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("(:name) -> ::String"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (:id, T) -> (::Integer | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (:name, T) -> (::String | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (:id) { (::Symbol) -> T } -> (::Integer | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (:name) { (::Symbol) -> T } -> (::String | T)"))
      end

      builder.shape(parse_type("{ id: ::Integer, name: self }"), config).tap do |shape|
        assert_equal parse_type("{ id: ::Integer, name: self }"), shape.type

        assert_includes(shape.methods[:[]].method_types, parse_method_type("(:id) -> ::Integer"))
        assert_includes(shape.methods[:[]].method_types, parse_method_type("(:name) -> self"))
        assert_includes(shape.methods[:[]].method_types, parse_method_type("(::Symbol) -> (self | ::Integer | nil)"))

        assert_includes(shape.methods[:[]=].method_types, parse_method_type("(:id, ::Integer) -> ::Integer"))
        assert_includes(shape.methods[:[]=].method_types, parse_method_type("(:name, self) -> self"))

        assert_includes(shape.methods[:fetch].method_types, parse_method_type("(:id) -> ::Integer"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("(:name) -> self"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (:id, T) -> (::Integer | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (:name, T) -> (self | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (:id) { (::Symbol) -> T } -> (::Integer | T)"))
        assert_includes(shape.methods[:fetch].method_types, parse_method_type("[T] (:name) { (::Symbol) -> T } -> (self | T)"))
      end
    end
  end

  def test_shape__union_try
    with_factory({ "a.rbs" => <<-RBS }, nostdlib: true) do
class BasicObject
end

class Object < BasicObject
  def try: [T] () { (self) -> T } -> T
end

class Module
end

class Class < Module
  def new: () -> instance
end

class Integer
end

class String
end

class Symbol
end
      RBS

      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("::Integer | ::String"), config).tap do |shape|
        assert_equal(
          shape.methods[:try].method_types,
          [
            parse_method_type("[T] () { (::Integer | ::String) -> T } -> T"),
          ]
        )
      end

      builder.shape(parse_type("::Integer | self"), config).tap do |shape|
        assert_equal(
          shape.methods[:try].method_types,
          [
            parse_method_type("[T] () { (::Integer | self) -> T } -> T"),
          ]
        )
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("::Integer | ::String"))).tap do |shape|
        assert_equal(
          shape.methods[:try].method_types,
          [
            parse_method_type("[T] () { (self) -> T } -> T"),
          ]
        )
      end
    end
  end

  def test_shape__bounded_variable
    with_factory({ "a.rbs" => <<~RBS }) do
        interface _Foo[T]
          def f: () -> self

          def g: () -> ::_Foo

          def h: () -> T
        end
      RBS

      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("A", variables: [:A]), config(variable_bounds: { A: parse_type("::_Foo[::String]") })).tap do |shape|
        assert_equal parse_type("A", variables: [:A]), shape.type

        assert_equal [parse_method_type("() -> A", variables: [:A])], shape.methods[:f].method_types
        assert_equal [parse_method_type("() -> ::_Foo")], shape.methods[:g].method_types
        assert_equal [parse_method_type("() -> ::String")], shape.methods[:h].method_types
      end

      builder.shape(parse_type("self"), config(self_type: parse_type("A", variables: [:A]), variable_bounds: { A: parse_type("::_Foo[::String]") })).tap do |shape|
        assert_equal parse_type("A", variables: [:A]), shape.type

        assert_equal [parse_method_type("() -> self")], shape.methods[:f].method_types
        assert_equal [parse_method_type("() -> ::_Foo")], shape.methods[:g].method_types
        assert_equal [parse_method_type("() -> ::String")], shape.methods[:h].method_types
      end
    end
  end

  def test_shape__big_literal_union
    names = 100.times.map {|i| "'#{i}'"}

    with_factory({ "a.rbs" => <<~RBS }) do
        type names = #{names.join(" | ")}
      RBS

      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("::names"), config).tap do |shape|
        assert_equal parse_type("::names"), shape.type

        assert_equal [parse_method_type("() -> (#{names.join(" | ")})")], shape.methods[:itself].method_types
      end
    end
  end

  # Every member declares `foo` twice with the same type — the shape `| ...`
  # gives a method already declared upstream. The union has one thing to say
  # about `foo`, so it must say it once: pairing the members' overloads off
  # against each other instead would leave 2 ** members of them, which is what
  # made a 30-member union of module singletons exhaust the machine's memory.
  def test_shape__union_does_not_multiply_overloads
    members = 12.times.map {|i| "::C#{i}" }

    with_factory({ "a.rbs" => <<~RBS }) do
        class Base
          def foo: (::Integer) -> void
        end

        #{members.map {|name| "class #{name} < Base\n  def foo: (::Integer) -> void | ...\nend\n" }.join("\n")}
      RBS

      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type(members.join(" | ")), config).tap do |shape|
        assert_equal [parse_method_type("(::Integer) -> void")], shape.methods[:foo].method_types

        # The collapsed overload still knows every member it came from.
        defined_in = shape.methods[:foo].overloads.flat_map {|overload| overload.method_defs.map {|defn| defn.defined_in.to_s } }
        assert_equal (["::Base"] + members).sort, defined_in.uniq.sort
      end
    end
  end

  # The members redeclare `foo` with `| ...`, so each has TWO overloads and the second
  # one — inherited, typed `-> self` — is a different type in every member. Folding the
  # members pairwise then produces a method type per subset: `-> (::Base | ::C0)`,
  # `-> (::Base | ::C1)`, ... doubling with each member, 2 ** 19 of them on the union
  # that motivated this (a generated `Module#include` in rbs_infer's dummy app).
  #
  # They are the same type: `::C0 <: ::Base`, so every combination that picks the
  # `-> ::Base` overload from any member returns `::Base`. Absorbing the covered
  # members says that once, and the union is left with the two things it can return.
  def test_shape__union_absorbs_covered_return_types
    members = 12.times.map {|i| "::C#{i}" }

    with_factory({ "a.rbs" => <<~RBS }) do
        class Base
          def foo: () -> self
        end

        #{members.map {|name| "class #{name} < Base\n  def foo: () -> ::Base | ...\nend\n" }.join("\n")}
      RBS

      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type(members.join(" | ")), config).tap do |shape|
        assert_equal(
          [
            parse_method_type("() -> ::Base"),
            parse_method_type("() -> (#{members.join(" | ")})")
          ].sort_by(&:to_s),
          shape.methods[:foo].method_types.sort_by(&:to_s)
        )
      end
    end
  end

  def test_shape__inline__class_singleton
    with_factory({}, { "a.rb" => <<-RUBY }) do
class Foo
  # @rbs (Integer) -> void
  def initialize(x)
  end
end
      RUBY

      builder = Interface::Builder.new(factory, implicitly_returns_nil: true)

      builder.shape(parse_type("singleton(::Foo)"), config).tap do |shape|
        assert_equal parse_type("singleton(::Foo)"), shape.type
        shape.methods[:new].tap do |method|
          assert_equal [parse_method_type("(::Integer) -> ::Foo")], method.method_types
        end
      end
    end
  end
end
