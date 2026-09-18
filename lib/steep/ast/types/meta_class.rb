module Steep
  module AST
    module Types
      # The singleton class of a module, as a VALUE.
      #
      # Steep can already spell `singleton(::Foo)` — the type of the object
      # `Foo` — but not the type of `Foo.singleton_class`, which is a different
      # object: the class whose INSTANCE methods are `Foo`'s class methods. With
      # only the first, `Foo.singleton_class` is `::Class` and the identity is
      # gone one step before anything is asked of it, which is where
      # `ActiveSupport::Delegation`'s reflection breaks (felixefelip/steep#171).
      #
      # A leaf, like `Literal`: it names a module and nothing else, and answers
      # every question as the `::Class` it is one of.
      #
      # Deliberately NOT nested: `Foo.singleton_class.singleton_class` is a
      # third object again, and nothing asks for it, so it declines rather than
      # being modelled.
      class MetaClass
        attr_reader :name

        def initialize(name:)
          @name = name
        end

        def ==(other)
          other.is_a?(MetaClass) &&
            other.name == name
        end

        def hash
          self.class.hash ^ name.hash
        end

        alias eql? ==

        def subst(s)
          self
        end

        # Reads as what it is, and cannot be confused with `singleton(::Foo)`,
        # which is the object this is the class OF.
        def to_s
          "singleton_class(#{name})"
        end

        include Helper::NoFreeVariables

        include Helper::NoChild

        def level
          [0]
        end

        def with_location(new_location)
          self
        end

        # What this is written as wherever exactness cannot travel — into RBS,
        # into a shape, into any consumer that knows `::Class` and not this.
        def back_type
          AST::Builtin::Class.instance_type
        end
      end
    end
  end
end
