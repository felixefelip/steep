module Steep
  module TypeInference
    # What a method body reads besides its parameters, its locals and
    # `self`'s ivars: class variables, constants and the methods it calls on
    # `self.class`, for `ObjectStates::KeyedMemo` to tell which of them stay as
    # they are; `outside_state` for the rest.
    #
    #     def implementation = @@implementation ||= Simple
    #     # cvars: [:@@implementation], const_reads: [["Tag::Simple", "Simple"]]
    class OutsideReads
      # What a body reads that no fact here follows: a global or a match.
      OUTSIDE = %i[gvar nth_ref back_ref].freeze

      NONE = { outside_state: false, own_class_sends: Set[].freeze, cvars: Set[].freeze, cvar_writes: Set[].freeze, const_reads: [].freeze, const_sends: [].freeze }.freeze

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
        @outside = false
        @own_class_sends = Set[]
        @called_classes = Set[].compare_by_identity
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
        { outside_state: @outside, own_class_sends: @own_class_sends, cvars: @cvars, cvar_writes: @cvar_writes, const_reads: @const_reads, const_sends: @const_sends }
      end

      def self.own_class?(node) = node.type == :send && node.children[1] == :class && node.children[0]&.type == :self

      private

      def record(node)
        @outside ||= OUTSIDE.include?(node.type) || (OutsideReads.own_class?(node) && !@called_classes.include?(node))
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
          record_send(node.children[0], node.children[1])
        end
      end

      def record_send(receiver, method_name)
        @const_sends << [@names.call(receiver), method_name] if receiver&.type == :const
        return unless receiver.is_a?(::Parser::AST::Node) && OutsideReads.own_class?(receiver)

        @called_classes << receiver
        @own_class_sends << method_name
      end
    end
  end
end
