module Steep
  module AST
    module Types
      # A regular expression written out in the source, as a VALUE.
      #
      # RBS has literal types for strings, symbols, integers and booleans, and
      # none for a pattern, so `/=\z/` is `::Regexp` and every question asked of
      # it is `bool`. That is where `ActiveSupport::Delegation.generate` loses
      # the `[]=` case (felixefelip/steep#171): it picks the setter branch with
      # `/[^\]]=\z/.match?(method)`, and `method` is a literal by then.
      #
      # A leaf, like `Literal`: it holds the pattern and nothing else, and
      # answers every question as the `::Regexp` it is one of. Only a pattern
      # with no interpolation is one — `/#{x}/` is a value the file does not fix.
      class RegexpLiteral
        include NotInRBS

        attr_reader :value

        def initialize(value:)
          @value = value
        end

        def ==(other)
          other.is_a?(RegexpLiteral) &&
            other.value == value
        end

        def hash
          self.class.hash ^ value.hash
        end

        alias eql? ==

        def subst(s)
          self
        end

        # The pattern as Ruby writes it, which no RBS type parses as — so it
        # cannot be mistaken for something a signature said.
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
          AST::Builtin::Regexp.instance_type
        end
      end
    end
  end
end
