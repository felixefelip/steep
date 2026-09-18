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
  #
  # What the value IS, this walk does not decide. It points at the node the
  # constant is written as — `%w(…)`, or a chain like
  # `(KEYWORDS + EXTRA).to_set.freeze` — and the checker folds that the way it
  # folds any other expression. Naming those operations here would be a second
  # table to keep in step with the first.
  module Constants
    # A body that runs on its own schedule. Unlike `Accumulators` this walk has
    # no reason to stop at a `def` — a constant is the same constant inside one
    # — but a BLOCK still takes the elements somewhere it does not follow.
    CLOSURES = %i[block numblock].freeze

    class << self
      include NodeHelper

      # `{ constant read node => [value node, the name it is written under] }`.
      #
      # The name goes with it because the map is keyed by the bare symbol and
      # the checker is the only one that knows which constant a bare read
      # actually resolved to: `RESERVED` read inside `module Other` is not
      # `Owner::RESERVED` just because this file writes one of those.
      def analyze(node)
        found = assignments(node)
        strike(node, found)

        reads = {}.compare_by_identity #: Hash[untyped, untyped]
        return reads if found.empty?

        each_node(node) do |child|
          next unless read?(child)

          entry = found[child.children[1]] or next
          reads[child] = entry
        end
        reads
      end

      private

      # `{ name => [value node, qualified name] }` for every constant this file
      # writes once, unconditionally, in the body of its own namespace.
      #
      # Two assignments of one name leave it unusable — which of them a read
      # means is a question about constant lookup, and this is a walk over one
      # file. So does one written anywhere but a namespace's own statements:
      #
      #     VALUE = ["a"] if ENV["FLAG"]
      #
      # is a constant that may not exist at all, and answering from the value
      # written there is a `NameError` told as a literal.
      def assignments(node)
        found = {} #: Hash[Symbol, untyped?]
        definitions = {}.compare_by_identity #: Hash[untyped, bool]

        each_definition(node) do |casgn, nesting|
          definitions[casgn] = true

          name = casgn.children[1]
          usable = !found.key?(name) && casgn.children[0].nil?
          value = usable ? initializer_of(casgn) : nil
          found[name] = value ? [value, ["", *nesting, name].join("::")] : nil
        end

        # Anything the walk above did NOT reach is an assignment under control
        # flow, inside a `class << self`, or under a scope of its own — each a
        # way for the name to hold something other than what it is written with.
        each_node(node) do |child|
          next unless child.type == :casgn
          next if definitions.key?(child)

          name = child.children[1]
          found[name] = nil if found.key?(name)
        end

        found.reject { |_, value| value.nil? }
      end

      # Every `casgn` written as a statement of a namespace's own body, with the
      # namespace it lands in. Descends through `class`, `module` and `begin`
      # and nothing else, so a conditional assignment is simply never reached.
      def each_definition(node, nesting = [], &block)
        return unless node.is_a?(Parser::AST::Node)

        case node.type
        when :class, :module
          path = const_path(node.children[0]) or return
          body = node.type == :class ? node.children[2] : node.children[1]
          each_definition(body, nesting + path, &block)
        when :begin
          node.children.each { |child| each_definition(child, nesting, &block) }
        when :casgn
          yield node, nesting
        end
      end

      def const_path(node)
        return [] if node.nil?
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :const

        prefix = const_path(node.children[0]) or return nil
        prefix + [node.children[1].to_s]
      end

      # The value as written. An array spelled out, another constant, or a chain
      # of calls over those — `(KEYWORDS + EXTRA).to_set.freeze` is how a
      # constant collection is usually written, and the checker folds the chain
      # itself rather than this walk naming those operations a second time.
      #
      # What is refused here is only the shape: whether the chain actually
      # answers a value is the fold's question, and a chain that does not simply
      # recovers nothing later.
      def initializer_of(casgn)
        value = casgn.children[2]
        collection_expression?(value) ? value : nil
      end

      def collection_expression?(node)
        return false unless node.is_a?(Parser::AST::Node)

        case node.type
        when :array
          !node.children.empty? && node.children.none? { |element| element.type == :splat }
        when :const
          read?(node)
        when :send
          collection_expression?(node.children[0])
        when :begin
          # `(KEYWORDS + EXTRA).to_set` — the parentheses are a node of their
          # own, and the value is what is inside them.
          node.children.one? && collection_expression?(node.children[0])
        else
          false
        end
      end

      def read?(node)
        node.is_a?(Parser::AST::Node) && node.type == :const && node.children[0].nil?
      end

      # Every mention that is not a plain read takes the name away — passed as an
      # argument, assigned to something, or the receiver of a call that is not on
      # the list above.
      #
      # `Accumulators#strike` is the same sentence about a local and is
      # deliberately a separate walk: it stops at a body of its own and turns a
      # reader inside a block into a strike, neither of which means anything for
      # a constant, and the node that WRITES one is a `casgn` whose value is not
      # a mention rather than an `lvasgn` whose value is. What the two agree on
      # is the list of reads, and that they share.
      def strike(node, found, closure: false)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :casgn
          # The assignment is where the value comes FROM, not a mention of it.
          strike(node.children[2], found, closure: closure)
          return
        end

        # A block takes the collection out of the question whatever the method:
        # `VALUES.count { |value| value << "b" }` hands every element to a body
        # this walk does not follow.
        if CLOSURES.include?(node.type)
          node.children.each { |child| strike(child, found, closure: true) }
          return
        end

        if !closure && node.type == :send && CollectionReaders.read?(node) && read?(node.children[0])
          node.children.drop(2).each do |argument|
            # The other side of a `+` is read, not handed anywhere.
            next if CollectionReaders.binary?(node) && read?(argument)

            strike(argument, found)
          end
          return
        end

        # A call ON the answer of one of those: `VALUES.first` hands back an
        # element, and the next call is free to change it in place.
        if node.type == :send && element_read?(node.children[0])
          strike(node.children[0].children[0], found)
          node.children.drop(1).each { |child| strike(child, found) }
          return
        end

        if read?(node)
          found[node.children[1]] = nil if found.key?(node.children[1])
          return
        end

        node.children.each { |child| strike(child, found, closure: closure) }
      end

      # A read that hands back an ELEMENT of a constant this walk is watching.
      def element_read?(node)
        node.is_a?(Parser::AST::Node) && node.type == :send &&
          CollectionReaders.element?(node) && read?(node.children[0])
      end

      # Every node of the file, the root included. A constant is not scoped the
      # way a local is — one written at the top is the same constant a method
      # body reads — so unlike `Accumulators`' walk this stops at nothing, and
      # `NodeHelper`'s plain descent is the whole of it.
      def each_node(node, &block)
        return unless node.is_a?(Parser::AST::Node)

        yield node
        each_descendant_node(node, &block)
      end
    end
  end
end
