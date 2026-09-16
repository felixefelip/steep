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
    # elements. Nothing the caller is left holding is part of the collection.
    WHOLE = %i[join size length empty? count include? intersect?].freeze

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
    end
  end
end
