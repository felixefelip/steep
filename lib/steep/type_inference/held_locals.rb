module Steep
  module TypeInference
    # The locals of one method body that no other name in it reaches, so every
    # change made to the object in them from this body is made through them,
    # in order (felixefelip/steep#205, stage 2).
    #
    #   reflection = Reflection.new(name)
    #   reflection.rename(as)
    #   Writer.define_stored(self, reflection)
    #
    # A local qualifies when it is assigned once and every mention of it is the
    # receiver of a call or an argument handed to one, and the only mention in
    # that call; a parameter, when it is never assigned. Any other mention may
    # give the object a second name (`other = reflection`, a return, a block
    # that runs later), or reach it out of order (inside a loop, a `rescue`,
    # or twice in one call).
    class HeldLocals
      SCOPES = %i[def defs class module sclass].freeze
      CALLS = %i[send csend].freeze
      LOOPS = %i[while until while_post until_post for].freeze
      REFLECTIVE = %i[binding eval local_variable_get local_variable_set].freeze

      def self.of(def_node)
        new(def_node)
      end

      def initialize(def_node)
        @names = Set[] #: Set[Symbol]
        @values = {}.compare_by_identity #: Hash[::Parser::AST::Node, Symbol]
        analyze(def_node) if def_node
      end

      def held?(name)
        @names.include?(name)
      end

      # Whether `node` is the value assigned to a held local.
      def held_value?(node)
        @values.key?(node)
      end

      private

      def analyze(def_node)
        args, body = def_node.type == :defs ? def_node.children.drop(2) : def_node.children.drop(1)
        @assignments = {} #: Hash[Symbol, Array[::Parser::AST::Node]]
        @escaped = Set[] #: Set[Symbol]
        @reflective = false
        @forwards = false
        [args, body].each { |root| walk(root, [], detached: false) { |node, parents, detached| visit(node, parents, detached) } }
        return if @reflective

        parameters = parameters(args)
        register(parameters, @assignments, @forwards ? @escaped | parameters : @escaped)
      end

      def visit(node, parents, detached)
        case node.type
        when :lvasgn
          name = node.children[0]
          node.children[1] && !detached ? (@assignments[name] ||= []) << node : @escaped << name
        when :lvar
          @escaped << node.children[0] if detached || !handed?(node, parents)
        when *CALLS
          @reflective ||= node.children[0].nil? && REFLECTIVE.include?(node.children[1])
        when :zsuper
          @forwards = true
        end
      end

      def register(parameters, assignments, escaped)
        parameters.each { |name| @names << name unless assignments.key?(name) || escaped.include?(name) }
        assignments.each do |name, nodes|
          next if nodes.size > 1 || parameters.include?(name) || escaped.include?(name)

          @names << name
          @values[nodes.first.children[1]] = name
        end
      end

      def walk(node, parents, detached:, &block)
        return unless node.is_a?(::Parser::AST::Node)
        return if SCOPES.include?(node.type)

        yield node, parents, detached
        inner = [*parents, node]
        node.children.each_with_index do |child, index|
          walk(child, inner, detached: detached || detaches?(node, index), &block)
        end
      end

      # The children of `node` that may run later, more than once, or after
      # the statements around them were cut short.
      def detaches?(node, index)
        case node.type
        when :block, :numblock, :rescue, :ensure then index > 0
        when *LOOPS then true
        else false
        end
      end

      def handed?(node, parents)
        parent = parents[-1] or return false
        call =
          if CALLS.include?(parent.type)
            parent if parent.children[0].equal?(node) || parent.children.drop(2).any? { |arg| arg.equal?(node) }
          elsif parent.type == :pair && parent.children[1].equal?(node) && parents[-2]&.type == :kwargs
            parents[-3] if CALLS.include?(parents[-3]&.type)
          end
        call ? mentions(call, node.children[0]) == 1 : false
      end

      def mentions(node, name)
        return 0 unless node.is_a?(::Parser::AST::Node)
        return 0 if SCOPES.include?(node.type)

        own = node.type == :lvar && node.children[0] == name ? 1 : 0
        own + node.children.sum { |child| mentions(child, name) }
      end

      def parameters(args)
        return [] unless args.is_a?(::Parser::AST::Node)

        args.children.filter_map do |param|
          param.children[0] if param.is_a?(::Parser::AST::Node) && %i[arg optarg kwarg kwoptarg].include?(param.type)
        end
      end
    end
  end
end
