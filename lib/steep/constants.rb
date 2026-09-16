module Steep
  # Constants whose value a file can be read to know.
  #
  #     RESERVED = %w(class def end)
  #     RESERVED.include?("content")   # false, once the read carries the list
  #
  # A constant is the one name Ruby means to be written once, so the value at a
  # read is the value at the assignment — which is exactly what an ordinary
  # local cannot promise, and why `Accumulators` has to work so much harder for
  # one. What is left to check is that this FILE is where the name is decided,
  # and that nothing here changes the object behind it:
  #
  #     RESERVED = %w(class def end)
  #     RESERVED << "begin"            # a value the assignment no longer states
  #
  # so any mention that is not a plain read takes the constant away. Reading it
  # is the point and costs nothing: `include?`, `join` and the rest answer about
  # the array without handing it anywhere.
  #
  # Only what this file assigns, and only at the top of its own namespace: a
  # constant written elsewhere is a value this walk has not seen, and one
  # written twice is a name it cannot resolve to a value at all. The checker
  # then holds the recovered value against the type the read actually resolved
  # to, so a name that turns out to be some OTHER constant is refused there.
  module Constants
    # Calls that answer about the collection without letting it out. `each` and
    # `map` are deliberately absent: they hand every element to a body this does
    # not follow, which is the same reason `Accumulators` stops at a block.
    READERS = %i[join first last size length empty? count fetch [] include? intersect?].freeze

    class << self
      # `{ constant read node => the node its value is written as }`.
      def analyze(node)
        found = assignments(node)
        strike(node, found)

        reads = {}.compare_by_identity #: Hash[untyped, untyped]
        return reads if found.empty?

        each_node(node) do |child|
          next unless read?(child)

          initializer = found[child.children[1]] or next
          reads[child] = initializer
        end
        reads
      end

      private

      # `{ name => value node }` for every constant this file writes once at the
      # top of its own namespace. A second assignment of the same name, or one
      # written under a scope (`Foo::BAR = …`), leaves the name unusable: which
      # of them a read means is a question about constant lookup, and this is a
      # walk over one file.
      def assignments(node)
        found = {} #: Hash[Symbol, untyped?]

        each_node(node) do |child|
          next unless child.type == :casgn

          name = child.children[1]
          # A second assignment, or one under a scope, and the value written is
          # no longer what this name states here.
          usable = !found.key?(name) && child.children[0].nil?
          found[name] = usable ? initializer_of(child) : nil
        end

        found.reject { |_, value| value.nil? }
      end

      # The value as written, with `.freeze` taken off — freezing is how a
      # constant collection is spelled and says nothing about what is in it.
      def initializer_of(casgn)
        value = casgn.children[2]
        value = value.children[0] if frozen?(value)
        return nil unless value.is_a?(Parser::AST::Node) && value.type == :array
        return nil if value.children.empty?
        return nil if value.children.any? { |element| element.type == :splat }

        value
      end

      def frozen?(node)
        node.is_a?(Parser::AST::Node) && node.type == :send &&
          node.children[1] == :freeze && node.children.size == 2
      end

      def read?(node)
        node.is_a?(Parser::AST::Node) && node.type == :const && node.children[0].nil?
      end

      # Every mention that is not a plain read takes the name away — passed as an
      # argument, assigned to something, or the receiver of a call that is not on
      # the list above.
      def strike(node, found)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :casgn
          # The assignment is where the value comes FROM, not a mention of it.
          strike(node.children[2], found)
          return
        end

        if node.type == :send && READERS.include?(node.children[1]) && read?(node.children[0])
          node.children.drop(2).each { |argument| strike(argument, found) }
          return
        end

        if read?(node)
          found[node.children[1]] = nil if found.key?(node.children[1])
          return
        end

        node.children.each { |child| strike(child, found) }
      end

      # Every node of the file. A constant is not scoped the way a local is: one
      # written at the top is the same constant a method body reads, so nothing
      # here stops at a body of its own.
      def each_node(node, &block)
        return unless node.is_a?(Parser::AST::Node)

        yield node
        node.children.each { |child| each_node(child, &block) }
      end
    end
  end
end
