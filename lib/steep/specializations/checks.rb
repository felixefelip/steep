module Steep
  module Specializations
    # The questions one check asked its `Store`, each with the answer it got,
    # in the order first asked. Everything that changes between generations
    # reaches a check through the store, so a later store answering each one
    # the same way is a store under which the check comes out the same.
    class Reads
      def initialize
        @entries = [] #: Array[[Symbol, Array[untyped], Hash[Symbol, untyped], untyped]]
        @answers = {} #: Hash[[Symbol, Array[untyped], Hash[Symbol, untyped]], Array[untyped]]
      end

      def record(name, arguments, options, answer)
        seen = (@answers[[name, arguments, options]] ||= [])
        return if seen.include?(answer)

        seen << answer
        @entries << [name, arguments, options, answer]
      end

      def same?(store)
        @entries.all? { |name, arguments, options, answer| store.answer(name, arguments, options) == answer }
      end
    end

    # What a computation over the store came to, kept across generations as
    # `Checks` keeps a check: handed back while the store answers what it asked
    # as before, with the class exits its checks left merged again.
    class Kept
      Entry = Struct.new(:reads, :value, :class_exits)

      def initialize
        @entries = {} #: Hash[untyped, Entry]
      end

      def clear = @entries.clear

      def value(key, store, class_exits)
        previous = @entries[key]
        if previous&.reads&.same?(store)
          previous.class_exits.each { |left| class_exits.merge!(left) }
          return previous.value
        end

        reads = Reads.new
        left = [] #: Array[Hash[untyped, untyped]]
        value = yield(store.with_reads(reads), left)
        @entries[key] = Entry.new(reads, value, left)
        value
      end
    end

    # What each specialized check of a file came to, kept across generations.
    # A generation whose store answers every question a check asked as it was
    # answered then is handed that check's outcome instead of checking again.
    class Checks
      Outcome = Struct.new(:reads, :returns, :exits, :sites, :class_exits, :receivers, keyword_init: true)

      # `returned`: the type a body returns in a typing, given its key and node.
      # `names`: the readers whose receivers an outcome records (`Receivers`).
      def initialize(overrides:, returned:, names:)
        @overrides = overrides
        @returned = returned
        @names = names
        @outcomes = {} #: Hash[untyped, Outcome]
      end

      def clear = @outcomes.clear

      # `bodies`: `{ key => [def_node, arguments, node_key, checked_arguments] }`
      # for the bodies of one file this check substitutes. The block checks the
      # file under the store and the substitutions it is given.
      def outcome(bodies, store)
        active = bodies.each_value.to_h { |_, _, node_key, checked| [node_key, checked] }
        previous = @outcomes[active]
        return previous if previous&.reads&.same?(store.with_active(active))

        reads = Reads.new
        @outcomes[active] = outcome_of(yield(store.with_reads(reads), active), bodies, reads)
      end

      private

      def outcome_of(typing, bodies, reads)
        return Outcome.new(reads: reads, returns: {}, exits: {}, sites: {}, class_exits: {}, receivers: {}) unless typing

        Outcome.new(
          reads: reads,
          returns: bodies.to_h { |key, (def_node, _)| [key, @returned.call(typing, def_node, key)] },
          exits: bodies.filter_map do |key, (def_node, arguments)|
            exit = typing.exit_ivars_of(node: def_node)
            [key, exit] if ObjectStates::KeptSelf.exit_kept?(arguments, exit)
          end.to_h,
          sites: Collector.call_sites(typing, overrides: @overrides),
          class_exits: typing.class_exits,
          receivers: bodies.to_h { |key, (def_node, _)| [key, Receivers.collect(typing, def_node, @names)] }
        )
      end
    end
  end
end
