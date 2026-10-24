module Steep
  module Accumulators
    # The values a method body leaves with: where it ends, and at each `return`.
    module ReturnedValues
      LOGIC = %i[or and].freeze

      module_function

      # The ends of one body: the statement it finishes on, and — because a body
      # that finishes on an `if` finishes on whichever arm ran — the ends inside
      # that. `return` is the same thing written earlier, so it is followed from
      # wherever it appears, through a block (which returns from the method
      # around it) but not into a body of its own.
      #
      # `||`/`&&` are followed only with `logic:`: the type of `a || b` is
      # narrower than `a`'s joined with `b`'s, so a reader of types stops there.
      def each_tail(node, logic: false, &block)
        return unless node.is_a?(Parser::AST::Node)
        return if SCOPES.include?(node.type)

        if node.type == :return
          # Bare, or a list: the `return` itself is what holds the value.
          node.children.size == 1 ? each_tail(node.children[0], logic: logic, &block) : yield(node)
        elsif (children = value_children(node)).empty? || (!logic && LOGIC.include?(node.type))
          yield node
        else
          children.each { |child| each_tail(child, logic: logic, &block) }
        end
      end

      # The children whose value `node`'s value may be.
      def value_children(node)
        case node.type
        when :begin, :kwbegin, :when, :in_pattern then [node.children.last]
        when :if, :case, :case_match then node.children.drop(1)
        when *LOGIC then node.children
        else []
        end
      end

      # `return` written anywhere but the end — inside an `if` that guards, in a
      # block, wherever. The value leaves from there just the same.
      def each_returns(node, logic: false, &block)
        each_return(node) { |returned| each_tail(returned, logic: logic, &block) }
      end

      # Every `return` that leaves the method `node` is the body of; one inside
      # a lambda leaves only the lambda.
      def each_return(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        return if SCOPES.include?(node.type) || (LAMBDA_BODIES.include?(node.type) && node.children[0].type == :lambda)
        return yield(node) if node.type == :return

        node.children.each { |child| each_return(child, &block) }
      end

      # Every value that leaves `body`: where it ends, and at each `return`.
      def each_value(body, logic: false, &block)
        each_tail(body, logic: logic, &block)
        each_returns(body, logic: logic, &block)
      end
    end
  end
end
