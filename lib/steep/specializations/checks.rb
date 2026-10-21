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

    # What each specialized check of a file came to, kept across generations.
    # A generation whose store answers every question a check asked as it was
    # answered then is handed that check's outcome instead of checking again.
    class Checks
      Outcome = Struct.new(:reads, :returns, :exits, :sites, :class_exits, keyword_init: true)

      # `returned`: the type a body returns in a typing, given its key and node.
      def initialize(overrides:, returned:)
        @overrides = overrides
        @returned = returned
        @outcomes = {} #: Hash[untyped, Outcome]
      end

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
        return Outcome.new(reads: reads, returns: {}, exits: {}, sites: {}, class_exits: {}) unless typing

        Outcome.new(
          reads: reads,
          returns: bodies.to_h { |key, (def_node, _)| [key, @returned.call(typing, def_node, key)] },
          exits: bodies.filter_map { |key, (def_node, arguments)| [key, typing.exit_ivars_of(node: def_node)] if arguments.stateful? || arguments.hands_records? }.to_h,
          sites: Collector.call_sites(typing, overrides: @overrides),
          class_exits: typing.class_exits
        )
      end
    end
  end
end
