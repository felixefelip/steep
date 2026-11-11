module Steep
  module Postconditions
    # The methods a class body defines only in a branch the checker found it
    # never takes, and those it defines in a branch it may or may not take
    # (felixefelip/steep#378):
    #
    #   class Map < MriMapBackend
    #     unless defined?(NonConcurrentMapBackend) and self < NonConcurrentMapBackend
    #       def [](key) = ...      # never defined on MRI
    #     end
    #
    #     def key(value) = ... unless method_defined?(:key)   # maybe defined
    #   end
    #
    # The project's index of bodies (`ConstructorBindingRegistry`) leaves out the
    # first kind, so the body that runs is the one an ancestor defines, and
    # names no body for the second, since either may run. A method with a
    # definition the checker always reaches is neither.
    class UnreachedDefinitions
      def initialize
        @states = Hash.new { |hash, key| hash[key] = Set[] } #: Hash[String, Set[Symbol]]
      end

      def add(source, typing)
        flow = Specializations::Evals::Flow.new(typing)
        states = {}.compare_by_identity #: Hash[Parser::AST::Node, Symbol]
        mark(source.node, :certain, flow, states)
        Specializations::Collector.each_definition(source) do |key, def_node|
          @states[key] << states.fetch(def_node, :certain)
        end
      end

      def unreached = keys { |states| states == Set[:dead] }

      def conditional = keys { |states| states.include?(:unknown) && !states.include?(:certain) }

      private

      def keys(&block) = @states.select { |_, states| block.call(states) }.keys.to_set

      def mark(node, state, flow, states)
        return unless node.is_a?(Parser::AST::Node)
        return states[node] = flow.dead?(node) ? :dead : state if node.type == :def || node.type == :defs

        if (branches = flow.branches(node))
          branches.each { |child, branch| mark(child, combine(state, branch), flow, states) }
        else
          node.children.each { |child| mark(child, state, flow, states) }
        end
      end

      def combine(outer, inner)
        return :dead if outer == :dead || inner == :dead

        outer == :unknown || inner == :unknown ? :unknown : :certain
      end
    end
  end
end
