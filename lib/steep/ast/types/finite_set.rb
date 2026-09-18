module Steep
  module AST
    module Types
      # A set whose members are KNOWN, one per distinct value.
      #
      # `Tuple` is the collection a file writes out in order and `Record` the one
      # it writes out by key; this is the third, and it exists for the one thing
      # a set is ever asked — whether a value is in it. That is decidable
      # exactly while the members are, so this carries the members rather than
      # an element type.
      #
      # RBS cannot spell it: there is no set literal, only `Set[Elem]`. So one
      # of these never arrives FROM a signature, and leaves as `::Set[union]`
      # wherever it has to be written down again. The distance between those two
      # points is the whole of what it buys.
      #
      # Unordered and without repeats, which is what makes it a set and not a
      # tuple: the members are normalised at construction, so two sets written
      # differently are the same type.
      class FiniteSet
        attr_reader :types

        def initialize(types:)
          @types = types.uniq.sort_by(&:to_s)
        end

        def ==(other)
          other.is_a?(FiniteSet) &&
            other.types == types
        end

        def hash
          self.class.hash ^ types.hash
        end

        alias eql? ==

        def subst(s)
          self.class.new(types: types.map {|ty| ty.subst(s) })
        end

        # Deliberately not `Set[…]`, which is the RBS generic and says something
        # weaker. A reader seeing this in a diagnostic should be able to tell
        # that the members are the answer and not the element type.
        def to_s
          "Set{#{types.join(", ")}}"
        end

        def free_variables()
          @fvs ||= each_child.with_object(::Set[]) do |type, set| #$ Set[variable]
            set.merge(type.free_variables)
          end
        end

        include Helper::ChildrenLevel

        def each_child(&block)
          if block
            types.each(&block)
          else
            types.each
          end
        end

        def map_type(&block)
          FiniteSet.new(types: types.map(&block))
        end

        def level
          [0] + level_of_children(types)
        end

        def with_location(new_location)
          self.class.new(types: types)
        end

        # The type this is written as wherever exactness cannot travel — across
        # a signature, into RBS, into any consumer that knows `Set` and not this.
        def element_type
          Union.build(types: types)
        end
      end
    end
  end
end
