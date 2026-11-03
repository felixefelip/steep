module Steep
  module Accumulators
    module Strikes
      module_function

      # An element read whose answer is KEPT under another name: that name can
      # change the element in place, as a call on the answer can.
      #
      #     y = parts.first
      #     y << "b"              # parts is ["ab"] from here on
      def strike_held_element(value, found)
        return unless CollectionReaders.element_read?(value)

        name = value.children[0].children[0]
        found[name] = nil if found.key?(name)
      end

      # Every local this statement so much as names stops being readable, except
      # where it is the receiver of a call that only READS the array — and not
      # even then inside a closure, whose body runs at a time this walk does not
      # know.
      def strike(node, found, closure: false)
        return unless node.is_a?(Parser::AST::Node)
        # Another body's locals, not these.
        return if SCOPES.include?(node.type)

        if CLOSURES.include?(node.type)
          node.children.each { |child| strike(child, found, closure: true) }
          return
        end

        # WRITTEN, so the pushes recorded so far were into an array the name no
        # longer holds:
        #
        #     parts = []
        #     parts << "a"
        #     parts = Array.new   # ← a different array from here on
        #     parts << "b"        #   `["b"]`, and `["a", "b"]` to anything
        #     parts               #   still counting from the first one
        #
        # Reached for every shape of write, because `op_asgn`, `or_asgn`,
        # `and_asgn` and each target of an `masgn` all hold an `lvasgn` of their
        # own. The one write that does NOT come through here is the birth
        # `parts = []`, which `read` takes before striking — and a SECOND one of
        # those it strikes itself, for this same reason.
        if node.type == :lvasgn
          name = node.children[0]
          found[name] = nil if found.key?(name)
          strike_held_element(node.children[1], found)
          strike(node.children[1], found, closure: closure)
          return
        end

        if ASSIGNMENTS.include?(node.type)
          strike_held_element(node.children.last, found)
        end

        if !closure && CollectionReaders.scalar_mapped_read?(node)
          node.children.drop(2).each do |argument|
            next if CollectionReaders.binary?(node) && argument.type == :lvar

            strike(argument, found, closure: closure)
          end
          return
        end

        if !closure && CollectionReaders.reads_arguments?(node)
          strike(node.children[0], found, closure: closure)
          node.children.drop(2).each { |argument| strike(argument, found, closure: closure) unless argument.type == :lvar }
          return
        end

        if !closure && node.type == :send && CollectionReaders.read?(node) && node.children[0]&.type == :lvar
          node.children.drop(2).each do |argument|
            # The other side of a `+` is read, not handed anywhere.
            next if CollectionReaders.binary?(node) && argument.type == :lvar

            strike(argument, found, closure: closure)
          end
          return
        end

        # A call ON the answer of one of those. `parts.first` hands back an
        # ELEMENT, and the next call is free to change it in place:
        #
        #     parts.first << "b"    # parts is ["ab"] from here on
        #
        # The read itself is still a read; what takes the local away is that
        # something else is holding one of its elements.
        if node.type == :send && CollectionReaders.element_read?(node.children[0])
          strike(node.children[0].children[0], found, closure: closure) unless CollectionReaders::ELEMENT_QUERIES.include?(node.children[1])
          node.children.drop(1).each { |child| strike(child, found, closure: closure) }
          return
        end

        if node.type == :lvar
          name = node.children[0]
          found[name] = nil if found.key?(name)
          return
        end

        node.children.each { |child| strike(child, found, closure: closure) unless !closure && CollectionReaders.operand?(node, child) }
      end
    end
  end
end
