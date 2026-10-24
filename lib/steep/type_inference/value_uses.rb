module Steep
  module TypeInference
    # Where a method body puts the value of each expression in it, where that
    # decides whether a hash a state keeps gets a second name
    # (felixefelip/steep#314):
    #
    #   foo.my_hash[:bar] = { num1: 5 }   # a statement: discarded
    #   foo.my_hash[:bar][:num1]          # `foo.my_hash[:bar]`: a receiver
    #   y = foo.my_hash[:bar]             # taken
    #
    # A receiver is left to the call made on it, which knows the method it
    # runs; a returned value, to the method's caller.
    class ValueUses
      CALLS = %i[send csend].freeze

      def initialize(def_node)
        @discarded = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        @returned = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        @receivers = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        body = def_node && (def_node.type == :defs ? def_node.children[3] : def_node.children[2])
        return unless body

        ReturnedValues.each_value(body) { |node| @returned << node }
        walk(body)
      end

      def receiver?(node) = @receivers.include?(node)

      # Discarded or returned: nothing in the body takes it.
      def left?(node) = @discarded.include?(node) || @returned.include?(node)

      # Neither left nor a receiver: something here takes it.
      def taken?(node) = !left?(node) && !receiver?(node)

      private

      def walk(node)
        return unless node.is_a?(::Parser::AST::Node)
        return if LocalReach::SCOPES.include?(node.type)

        case node.type
        when :begin, :kwbegin
          node.children[0...-1].each { |child| @discarded << child }
        when *CALLS
          @receivers << node.children[0] if node.children[0].is_a?(::Parser::AST::Node)
        end
        node.children.each { |child| walk(child) }
      end
    end
  end
end
