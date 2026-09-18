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
    WHOLE = %i[join size length empty? count include? intersect? + - & | to_set].freeze

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
    end
  end
end
