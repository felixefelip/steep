module Steep
  module TypeInference
    # The names of the calls whose answer a source takes: every call but one
    # made as a statement whose value nothing reads, and every name a source
    # writes as a symbol or a string, which a `send` or a `method` may call
    # by. A method none of whose calls is taken answers nothing anyone holds.
    module TakenAnswers
      def self.of(node, taken = Set[])
        walk(node, false, taken)
        taken
      end

      def self.walk(node, taken_value, taken)
        return unless node.is_a?(::Parser::AST::Node)

        name = node.children[0]
        return taken << name.to_sym if %i[sym str].include?(node.type) && (name.is_a?(String) || name.is_a?(Symbol))

        taken << node.children[1] if taken_value && %i[send csend].include?(node.type)
        child_values(node, taken_value).each { |child, value| walk(child, value, taken) }
      end

      # Each child of `node`, with whether what it evaluates to is taken.
      def self.child_values(node, taken_value)
        children = node.children
        case node.type
        when :begin, :kwbegin then children.each_with_index.map { |child, index| [child, index == children.size - 1 && taken_value] }
        when :if then [[children[0], true], *children.drop(1).map { |child| [child, taken_value] }]
        when :def then [[children[1], true], [children[2], !Project::ConstructorBindingRegistry::INITIALIZERS.include?(children[0])]]
        when :class, :module, :sclass then [*children[0...-1].map { |child| [child, true] }, [children.last, false]]
        else children.map { |child| [child, true] }
        end
      end
    end
  end
end
