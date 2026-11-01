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
      include NodeHelper

      CALLS = %i[send csend super].freeze
      LOOPS = [*LocalReach::REPEATS, :for].freeze

      # `reassigned`: the parameters the body assigns
      # (`ArgumentFacts.reassigned_parameters`).
      def self.of(def_node, reassigned:)
        new(def_node, reassigned: reassigned)
      end

      def initialize(def_node, reassigned:)
        @names = Set[] #: Set[Symbol]
        @reading = Set[] #: Set[Symbol]
        @reads = {} #: Hash[Symbol, Array[::Parser::AST::Node]]
        @before_calls_on_it = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        @values = {}.compare_by_identity #: Hash[::Parser::AST::Node, Symbol]
        @returned_parameters = Set[] #: Set[Symbol]
        @reassigned = reassigned
        analyze(def_node) if def_node
      end

      def held?(name)
        @names.include?(name)
      end

      # `held?`, but for a parameter that is also a value the body returns, as
      # its last mention: the caller gets the object back under a second name,
      # which `HashMutation.handed_back` accounts for a record and nothing does
      # for an object's state.
      def held_up_to_its_return?(name)
        held?(name) || @returned_parameters.include?(name)
      end

      def held_value?(node)
        @names.include?(@values[node])
      end

      # Whether `name` is held but for the calls `calls_on_it` lists, made on
      # it inside an argument of a call it is handed to, before that call runs:
      #
      #   options[:extend] = [*options[:extend], extension]
      #   options[:query_constraints] = options.delete(:foreign_key)
      #
      # Held where each leaves the object as it found it, or changes it before
      # a call made on it (`before_a_call_on_it?`), which only the checker can
      # tell.
      def held_but_for_calls_on_it?(name)
        @reading.include?(name)
      end

      def calls_on_it(name)
        @reads.fetch(name, [])
      end

      # Whether `call` runs inside an argument of a call made on the same
      # local, which reaches the object as `call` left it.
      def before_a_call_on_it?(call)
        @before_calls_on_it.include?(call)
      end

      # Whether the local `name` is assigned a hash written there.
      def written_hash?(name)
        @values.any? { |node, held| held == name && node.type == :hash }
      end

      private

      def analyze(def_node)
        args, body = def_node.type == :defs ? def_node.children.drop(2) : def_node.children.drop(1)
        reach = LocalReach.reach(args, body)
        return if reach.every

        @assignments = {} #: Hash[Symbol, Array[::Parser::AST::Node]]
        @escaped = Set.new(reach.names) #: Set[Symbol]
        @forwards = false
        @def_node = def_node
        @returned = Set[].compare_by_identity #: Set[::Parser::AST::Node]
        Accumulators::ReturnedValues.each_value(body) { |node| @returned << node if node.type == :lvar }
        @returned_names = Set[] #: Set[Symbol]
        [args, body].each { |root| walk(root, [], detached: false) { |node, parents, detached| visit(node, parents, detached) } }

        parameters = parameters(args)
        @escaped.merge(@returned_names - parameters)
        register(parameters, @assignments, @forwards ? @escaped | parameters : @escaped)
        @returned_parameters = @names & @returned_names
        @names -= @returned_parameters
      end

      def visit(node, parents, detached)
        case node.type
        when :lvasgn
          name = node.children[0]
          node.children[1] && !detached ? (@assignments[name] ||= []) << node : @escaped << name
        when :lvar
          name = node.children[0]
          return if !detached && handed?(node, parents)
          return @returned_names << name if !detached && @returned.include?(node)

          reads = (reads_in_arguments(node, parents) unless detached)
          reads ? (@reads[name] ||= []).concat(reads) : @escaped << name
        when :zsuper
          hand_on_parameters(node, parents, detached)
        end
      end

      def register(parameters, assignments, escaped)
        register_held(parameters, assignments, escaped)
        @reading = @names & @reads.keys
        @names -= @reading
      end

      def register_held(parameters, assignments, escaped)
        parameters.each { |name| @names << name unless @reassigned.include?(name) || escaped.include?(name) }
        assignments.each do |name, nodes|
          next if nodes.size > 1 || parameters.include?(name) || escaped.include?(name)

          @names << name
          @values[nodes.first.children[1]] = name
        end
      end

      def walk(node, parents, detached:, &block)
        return unless node.is_a?(::Parser::AST::Node)
        return if LocalReach::SCOPES.include?(node.type)

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
        when *LocalReach::CLOSURES, :rescue, :ensure then index > 0
        when *LOOPS then true
        else false
        end
      end

      # A bare `super` hands on every parameter as the local it is there, once
      # (`NodeHelper#explicit_super`); one that may run later, or passes a
      # parameter with no name, hands on the frame.
      def hand_on_parameters(node, parents, detached)
        return @forwards = true if detached || explicit_super(node, @def_node).nil?

        call = parents.last(3).reverse.find { |parent| CALLS.include?(parent.type) } or return
        parameters(@def_node.children[@def_node.type == :defs ? 2 : 1]).each { |name| @escaped << name if LocalReach.mentions(call, name).positive? }
      end

      # A keyword argument's value sits two nodes below its call.
      def handed?(node, parents)
        call = parents.last(3).reverse.find { |parent| CALLS.include?(parent.type) } or return false
        handed = receiver?(call, node) ||
                 LocalReach.argument_values(arguments_of(call)).any? { |value| value.equal?(node) }
        handed && LocalReach.mentions(call, node.children[0]) == 1
      end

      def receiver?(call, node)
        call.type != :super && call.children[0].equal?(node)
      end

      def arguments_of(call)
        call.type == :super ? call.children : call.children.drop(2)
      end

      # The calls each other mention of `node`'s local in the arguments of the
      # call it is handed to is the receiver of, or nil where one is not.
      def reads_in_arguments(node, parents)
        call = parents.last(3).reverse.find { |parent| CALLS.include?(parent.type) } or return nil
        return nil unless receiver?(call, node) || LocalReach.argument_values(arguments_of(call)).any? { |value| value.equal?(node) }

        reads = [] #: Array[::Parser::AST::Node]
        arguments_of(call).each do |argument|
          each_mention(argument, node.children[0], nil) do |mention, parent|
            next if mention.equal?(node)
            return nil unless mention.type == :lvar && parent && CALLS.include?(parent.type) && receiver?(parent, mention)

            reads << parent
          end
        end
        return nil if reads.empty?

        @before_calls_on_it.merge(reads) if receiver?(call, node)
        reads
      end

      def each_mention(node, name, parent, &block)
        return unless node.is_a?(::Parser::AST::Node)
        return if LocalReach::SCOPES.include?(node.type)

        yield node, parent if %i[lvar lvasgn].include?(node.type) && node.children[0] == name
        node.children.each { |child| each_mention(child, name, node, &block) }
      end

      def parameters(args)
        return [] unless args.is_a?(::Parser::AST::Node)

        args.children.filter_map do |param|
          param.children[0] if param.is_a?(::Parser::AST::Node) && %i[arg procarg0 optarg kwarg kwoptarg kwrestarg].include?(param.type)
        end
      end
    end
  end
end
