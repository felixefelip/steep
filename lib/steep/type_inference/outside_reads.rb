module Steep
  module TypeInference
    # The class variables and constants a method body reads, for
    # `ObjectStates::KeyedMemo` to tell which of them stay as they are.
    #
    #     def implementation = @@implementation ||= Simple
    #     # cvars: [:@@implementation], const_reads: [["Tag::Simple", "Simple"]]
    class OutsideReads
      # What a body reads that no fact here follows: a global or a match.
      OUTSIDE = %i[gvar nth_ref back_ref].freeze

      NONE = { cvars: Set[].freeze, cvar_writes: Set[].freeze, const_reads: [].freeze, const_sends: [].freeze }.freeze

      # `names` answers the names a constant node may resolve to.
      def self.of(body, &names)
        new(names).tap { |reads| reads.visit(body) }.facts
      end

      # The methods of `tables` (`{ class name => { method name => [Body or
      # nil] } }`) that assign one of `cvars` other than by `||=`; every one
      # that assigns a class variable that way where `cvars` is nil.
      def self.writers(tables, cvars)
        methods = tables.flat_map { |table| table.each_value.flat_map(&:to_a) }
        methods.filter_map { |name, bodies| name if bodies.any? { |body| body && (cvars ? body.cvar_writes.intersect?(cvars) : !body.cvar_writes.empty?) } }.to_set
      end

      def initialize(names)
        @names = names
        @cvars = Set[]
        @cvar_writes = Set[]
        @memoized = Set[].compare_by_identity
        @const_reads = []
        @const_sends = []
      end

      def visit(node)
        return unless node.is_a?(::Parser::AST::Node)

        record(node)
        node.children.each { |child| visit(child) }
      end

      def facts
        { cvars: @cvars, cvar_writes: @cvar_writes, const_reads: @const_reads, const_sends: @const_sends }
      end

      private

      def record(node)
        case node.type
        when :or_asgn
          target = node.children[0]
          if target.type == :cvasgn
            @memoized << target
            @cvars << target.children[0]
          end
        when :cvar
          @cvars << node.children[0]
        when :cvasgn
          @cvar_writes << node.children[0] unless @memoized.include?(node)
        when :const
          @const_reads << @names.call(node)
        when :send, :csend
          receiver = node.children[0]
          @const_sends << [@names.call(receiver), node.children[1]] if receiver&.type == :const
        end
      end
    end
  end
end
