module Steep
  module Accumulators
    # What `elements` become once `key` has run over them in place, which is
    # what `fold_key` would answer for its copy (`RESHAPES`).
    Reshaped = Struct.new(:key, :fold_key, :elements)

    # The in-place methods a statement may run on a local, keyed by the one
    # that answers what they leave in it.
    RESHAPES = { uniq!: "::Array#uniq", compact!: "::Array#compact" }.freeze

    # What `elements` become once `block`, a `map!` on the local, has stored
    # what it hands back for each: the collection the checker computed for
    # that call.
    Mapped = Struct.new(:block, :elements)

    MAPS = %i[map! collect!].freeze

    # The statements that add to a watched local, or run one of `RESHAPES` on
    # it, read off their shape alone. Which elements those add is the
    # checker's to say (`Contents`).
    module Appends
      module_function

      # `[name, [value or Spliced, …]]` where this statement pushes onto a
      # watched local. More than one value for `parts << a << b`: `<<` hands
      # back the array it was called on, so each link of the chain pushes onto
      # the same one.
      def push_onto(statement, found)
        return added_onto(statement, found) if statement.is_a?(Parser::AST::Node) && statement.type == :op_asgn

        values = [] #: Array[untyped]
        node = statement

        while (appended = appended_values(node))
          values.unshift(*appended)
          node = node.children[0]
        end

        return nil if values.empty?
        return nil unless node&.type == :lvar

        name = node.children[0]
        return nil unless found[name]

        [name, values]
      end

      # What one link of a push chain appends, or nil where `node` is no push.
      def appended_values(node)
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :send

        _, method_name, *arguments = node.children
        return nil if arguments.any? { |argument| argument.type == :block_pass }

        case method_name
        when :<<
          arguments if arguments.size == 1
        when :push, :append
          arguments.map { |argument| argument.type == :splat ? Spliced.new(argument.children[0], "::Array#push") : argument }
        when :concat
          arguments.map { |argument| Spliced.new(argument, "::Array#concat") } unless arguments.any? { |argument| argument.type == :splat }
        end
      end

      # `parts += more` builds a new array where `parts` held the old one, and
      # nothing else held that.
      def added_onto(statement, found)
        target, operator, value = statement.children
        return nil unless target.type == :lvasgn && operator == :+

        name = target.children[0]
        return nil unless found[name]

        [name, [Spliced.new(value, "::Array#+")]]
      end

      # `{ name => entries }`, what the watched local this statement pushes
      # onto or reshapes holds once it has run. A `MAPS` call counts only with
      # a block that names no watched local.
      def changed(statement, found)
        if (push = push_onto(statement, found))
          name, values = push
          { name => found[name] + values }
        elsif (name = reshaped_local(statement, found))
          { name => [reshape(statement, found[name])] }
        elsif (name = mapped_local(statement, found))
          { name => [Mapped.new(statement, found[name])] }
        end
      end

      def reshaped_local(statement, found)
        return nil unless statement.is_a?(Parser::AST::Node) && statement.type == :send

        receiver, method_name, *arguments = statement.children
        return nil unless arguments.empty? && RESHAPES.key?(method_name) && receiver&.type == :lvar

        name = receiver.children[0]
        found[name] ? name : nil
      end

      def mapped_local(statement, found)
        return nil unless statement.is_a?(Parser::AST::Node) && LAMBDA_BODIES.include?(statement.type)

        call, _, body = statement.children
        receiver, method_name, *arguments = call.children
        return nil unless call.type == :send && arguments.empty? && MAPS.include?(method_name) && receiver&.type == :lvar

        name = receiver.children[0]
        found[name] && found.each_key.none? { |local| LocalReach.mentions(body, local).positive? } ? name : nil
      end

      def reshape(statement, elements)
        method_name = statement.children[1]
        Reshaped.new("::Array##{method_name}", RESHAPES.fetch(method_name), elements)
      end
    end
  end
end
