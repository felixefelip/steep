module Steep
  module AST
    module Types
      # A range of integers written out in the source, as a VALUE: the operand
      # `"person"[1..-1]` slices with. RBS has no literal type for a range, and
      # `1..-1` is `::Range[::Integer]`, which says nothing about where it starts
      # or ends.
      #
      # Read off the node only where a fold takes it as an operand, like
      # `RegexpLiteral`, and answers every other question as the range it is one
      # of.
      class RangeLiteral
        include NotInRBS

        attr_reader :value

        def initialize(value:)
          @value = value
        end

        def ==(other)
          other.is_a?(RangeLiteral) &&
            other.value == value
        end

        def hash
          self.class.hash ^ value.hash
        end

        alias eql? ==

        def subst(s)
          self
        end

        def to_s
          value.inspect
        end

        include Helper::NoFreeVariables

        include Helper::NoChild

        def level
          [0]
        end

        def with_location(new_location)
          self
        end

        def back_type
          AST::Builtin::Range.instance_type(AST::Builtin::Integer.instance_type)
        end
      end
    end
  end
end
