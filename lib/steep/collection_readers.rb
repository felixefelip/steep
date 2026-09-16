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
    METHODS = %i[join first last size length empty? count fetch [] include? intersect?].freeze
  end
end
