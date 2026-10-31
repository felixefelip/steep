module Steep
  module Accumulators
    # The statements a watched local is born in, read off their shape alone.
    module Births
      module_function

      # `[name, elements]` for each local this statement gives birth to: one
      # born from an array literal, or from a call (`Built`) the checker may
      # vouch for, or one target of `a, b = [], []` paired with its own.
      def seeds(statement)
        return [] unless statement.is_a?(Parser::AST::Node)

        case statement.type
        when :lvasgn
          [seed_of(*statement.children)].compact
        when :masgn
          targets, value = statement.children
          return [] unless array_literal?(value) && targets.children.size == value.children.size
          return [] unless targets.children.all? { |target| target.type == :lvasgn }

          targets.children.zip(value.children).filter_map { |target, element| seed_of(target.children[0], element) }
        else
          []
        end
      end

      def seed_of(name, value)
        return [name, value.children.dup] if array_literal?(value)

        [name, [Built.new(value)]] if built_call?(value)
      end

      def array_literal?(node)
        node.is_a?(Parser::AST::Node) && node.type == :array &&
          node.children.none? { |child| child.type == :splat }
      end

      # A value a local can be born from as a `Built`: a call, with or without
      # a block.
      def built_call?(node)
        return false unless node.is_a?(Parser::AST::Node)

        node.type == :send || (node.type == :block && node.children[0].type == :send)
      end
    end
  end
end
