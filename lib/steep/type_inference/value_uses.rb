module Steep
  module TypeInference
    # What a method body does with the value of each call in it, where that
    # decides whether a hash a state holds gets a second name
    # (felixefelip/steep#314):
    #
    #   foo.my_hash[:bar][:num2] = 30   # `foo.my_hash`, `foo.my_hash[:bar]`: steps
    #   foo.my_hash[:bar] = { num1: 5 } # a statement: discarded
    #   y = foo.my_hash[:bar]           # kept
    #
    # A step is the receiver of a key read, a key store or `delete`, or of a
    # read that hands nothing out. The method's last statement is returned:
    # its caller decides what the value meets.
    class ValueUses
      STEP_CALLS = %i[[] []= store delete key? has_key? include? member? size length empty? keys].to_set.freeze
      CALLS = %i[send csend].freeze

      def initialize(def_node)
        @steps = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        @discarded = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        @returned = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        body = def_node && (def_node.type == :defs ? def_node.children[3] : def_node.children[2])
        return unless body

        statements = body.type == :begin ? body.children : [body]
        @returned << statements.last
        walk(body)
      end

      def step?(node) = @steps.include?(node)

      # Neither discarded nor returned: something in the body takes it.
      def kept?(node) = !@discarded.include?(node) && !@returned.include?(node)

      private

      def walk(node)
        return unless node.is_a?(::Parser::AST::Node)
        return if LocalReach::SCOPES.include?(node.type)

        case node.type
        when :begin, :kwbegin
          node.children[0...-1].each { |child| @discarded << child }
        when *CALLS
          receiver = node.children[0]
          @steps << receiver if receiver.is_a?(::Parser::AST::Node) && STEP_CALLS.include?(node.children[1])
        end
        node.children.each { |child| walk(child) }
      end
    end
  end
end
