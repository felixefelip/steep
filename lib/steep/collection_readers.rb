module Steep
  # Calls that answer ABOUT a collection without letting it out.
  #
  # Two walks need this list, and need it to mean the same thing. `Accumulators`
  # vouches for a local built by `<<`, `Constants` for a name written once, and
  # both vouch only while nothing can change the value behind the reader's back
  # — so both have to agree on which calls cannot.
  #
  # A call missing from here is missing because the list IS the claim, not
  # because nobody thought of it: `each` and `map` hand every element to a body
  # neither walk follows, `reverse!` says what it does, and a name this cannot
  # vouch for costs an imprecise answer rather than a wrong one.
  module CollectionReaders
    # Answer with something NEW — a count, a boolean, a string built out of the
    # elements, another collection. Nothing the caller is left holding is part
    # of the receiver, so a constant is still the value it was written with
    # after one of these: `(KEYWORDS + EXTRA).to_set` reads both and changes
    # neither.
    WHOLE = %i[join size length empty? count include? intersect? + - & | to_set flatten uniq compact].freeze

    # Answer with an ELEMENT, which the caller may then change in place:
    #
    #     VALUES.first << "b"       # VALUES is ["ab"] from here on
    #
    # so one of these is a read only while its result goes nowhere a call can
    # reach it. Reading the element is the whole point of `first`, and the
    # mutation is the rare half — refusing them outright would cost every
    # honest use to catch that one.
    ELEMENT = %i[first last fetch []].freeze

    METHODS = (WHOLE + ELEMENT).freeze

    # Calls whose ARGUMENT is another collection, read exactly the way the
    # receiver is: `KEYWORDS + EXTRA` reads both and changes neither, where
    # `parts.include?(x)` takes a value that has nothing to do with the
    # collection it is being looked for in.
    BINARY = %i[+ - & | intersect?].freeze

    # Calls that change their receiver out of the arrays they are handed and
    # keep none of them: `concat` copies the elements across, as `+` does.
    ARGUMENT_READS = %i[concat].freeze

    # Calls that hand each element to a block and change nothing themselves
    # (`IterationIntrinsics`). `read?` refuses them, because the block may
    # change an element in place. They read the collection only together with
    # a proof that the block cannot: that it names each element only as an
    # argument of a call in `ElementReads`, or in an interpolation
    # (`TypeInference::ClassMemoAnalyzer#element_calls`). `Accumulators` and
    # `Constants` make no such proof, so for them a block stays out.
    ITERATIONS = %i[each map collect filter_map any?].freeze

    class << self
      # Whether this send only READS its receiver. A block takes it out of the
      # question whatever the method: `count { |value| value << "b" }` hands
      # every element to a body neither walk follows, and the collection is a
      # different one when it returns.
      def read?(send_node, block: false)
        return false if block

        METHODS.include?(send_node.children[1])
      end

      def element?(send_node)
        ELEMENT.include?(send_node.children[1])
      end

      # Whether this send reads its argument as a collection rather than using
      # it as a value.
      def binary?(send_node)
        BINARY.include?(send_node.children[1])
      end

      # Whether `mention` is the receiver of a `map(&:reader)` that a scalar
      # read consumes, outside any closure or loop in `node`.
      def mapped_read_of?(node, mention, inside = false)
        return false unless node.is_a?(Parser::AST::Node)
        return false if LocalReach::SCOPES.include?(node.type)

        if !inside && node.type == :send && scalar_mapped_read?(node)
          return true if node.children[0].children[0].equal?(mention)
        end

        repeats = inside || LocalReach::CLOSURES.include?(node.type) || LocalReach::REPEATS.include?(node.type)
        node.children.any? { |child| mapped_read_of?(child, mention, repeats) }
      end

      # `local.map(&:first).intersect?(…)`: the elements `map` picks are shared
      # with the local, and the scalar read hands none of them on.
      def scalar_mapped_read?(node)
        node.type == :send && Accumulators::SCALAR_READS.include?(node.children[1]) && mapped_read?(node.children[0])
      end

      def mapped_read?(node)
        return false unless node.is_a?(Parser::AST::Node) && node.type == :send
        return false unless Accumulators::BLOCK_READS.include?(node.children[1]) && node.children.size == 3
        return false unless node.children[0]&.type == :lvar

        pass = node.children[2]
        pass.type == :block_pass && pass.children[0]&.type == :sym &&
          METHODS.include?(pass.children[0].children[0])
      end

      def reads_arguments?(send_node)
        send_node.type == :send && ARGUMENT_READS.include?(send_node.children[1])
      end

      # The children of `node` that read a local array as a collection, copying
      # its elements out and keeping none of the array: `*parts` written in an
      # array literal, and a local on the right of a `+`.
      def operands(node)
        case node.type
        when :array then node.children.select { |child| child.type == :splat && child.children[0]&.type == :lvar }
        when :send then binary?(node) ? node.children.drop(2).select { |argument| argument.type == :lvar } : []
        else []
        end
      end

      def operand?(node, child)
        operands(node).any? { |operand| operand.equal?(child) }
      end

      # `[site, local]` for each place `node` reads a local array: the receiver
      # of a reader, at the call, and each of its `operands`, at the local.
      def read_sites(node)
        sites = operands(node).map { |operand| operand.type == :splat ? operand.children[0] : operand }.map { |local| [local, local] }
        reader = node.type == :send && (METHODS.include?(node.children[1]) || Accumulators::BLOCK_READS.include?(node.children[1]))
        sites << [node, node.children[0]] if reader && node.children[0]&.type == :lvar
        sites
      end
    end
  end
end
