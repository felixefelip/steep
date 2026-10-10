module Steep
  # What reaches a local of one method body other than its own name. Shared by
  # the analyses that vouch for a value only while nothing else can reach it:
  # `Accumulators`, `LocalAssignments` and `TypeInference::HeldLocals`.
  module LocalReach
    # Nodes that open a body of their own. A local named inside one is a
    # different variable that happens to share a name.
    SCOPES = %i[def defs class module sclass].freeze

    # Nodes whose body closes over the locals around it but runs on its own
    # schedule.
    CLOSURES = %i[block numblock].freeze

    # Loops whose condition and body both run once per turn.
    REPEATS = %i[while until while_post until_post].freeze

    # Calls that reach a local by a name given as a value, so no mention of it
    # is written. `binding` on any receiver (`Kernel`, `self`, a proc) hands out
    # the frame; a string any of `STRING_EVALS` runs is run in it.
    STRING_EVALS = %i[eval instance_eval class_eval module_eval].freeze
    DISPATCHES = %i[send __send__ public_send].freeze
    METHOD_OBJECTS = %i[method instance_method].freeze

    LOCALS = %i[lvar lvasgn].freeze
    COMPOUND_ASSIGNMENTS = %i[op_asgn or_asgn and_asgn masgn].freeze

    # The locals of a body something other than their own name can reach.
    Reach = Struct.new(:every, :names) do
      def include?(name) = every || names.include?(name)
      def any?(locals) = locals.any? { |name| include?(name) }
    end
    NOWHERE = Reach.new(false, Set[].freeze).freeze
    EVERYWHERE = Reach.new(true, Set[].freeze).freeze

    module_function

    # Every node of `node`, stopping at a body of its own.
    def each_node(node, &block)
      return unless node.is_a?(Parser::AST::Node)
      return if SCOPES.include?(node.type)

      yield node
      node.children.each { |child| each_node(child, &block) }
    end

    # How many times `node` reads or writes `name`.
    def mentions(node, name)
      count = 0
      each_node(node) do |child|
        count += 1 if (child.type == :lvar || child.type == :lvasgn) && child.children[0] == name
      end
      count
    end

    # A frame handed out reaches every local, and so does a string run where it
    # may run twice. A string run once reaches only what runs after it: the
    # locals mentioned later, the one its value is assigned to, and those whose
    # values the caller reads once the body returns (`outliving`).
    def reach(*roots, outliving: [])
      evals = string_evals(roots) or return EVERYWHERE
      return NOWHERE if evals.empty?
      return EVERYWHERE if roots.any? { |root| retries?(root) }

      names = Set.new(outliving) #: Set[Symbol]
      evals.each do |call, ancestors|
        ancestors.each { |ancestor| names.merge(assigned_by(ancestor)) }
        roots.each do |root|
          each_node(root) { |node| names << node.children[0] if LOCALS.include?(node.type) && after?(node, call) }
        end
      end
      Reach.new(false, names)
    end

    # Each string run once, with the nodes it is written in; nil where the
    # frame is handed out or a string may run more than once.
    def string_evals(roots)
      evals = [] #: Array[[untyped, Array[untyped]]]
      roots.each do |root|
        each_call(root, [], false) do |call, ancestors, repeated|
          case frame_access(call.children[1], call.children.drop(2))
          when :frame
            return nil
          when :string
            return nil if repeated || !call.location&.expression

            evals << [call, ancestors]
          end
        end
      end
      evals
    end

    def each_call(node, ancestors, repeated, &block)
      return unless node.is_a?(Parser::AST::Node)
      return if SCOPES.include?(node.type)

      yield node, ancestors, repeated if node.type == :send || node.type == :csend
      inner = [*ancestors, node]
      node.children.each_with_index do |child, index|
        each_call(child, inner, repeated || repeats?(node, index), &block)
      end
    end

    def repeats?(node, index)
      case node.type
      when *CLOSURES then index > 0
      when *REPEATS then true
      when :for then index != 1
      else false
      end
    end

    # The block form of an `*_eval` is a closure, which is read as one; only an
    # argument is a string to run. A name chosen at run time may be any of them.
    def frame_access(name, arguments)
      return :frame if name == :binding
      return :string if STRING_EVALS.include?(name) && arguments.any? { |argument| argument.type != :block_pass }

      target, *rest = arguments
      return unless target && (DISPATCHES.include?(name) || METHOD_OBJECTS.include?(name))
      return :frame unless target.type == :sym || target.type == :str

      target_name = target.children[0].to_sym
      return :frame if METHOD_OBJECTS.include?(name) && STRING_EVALS.include?(target_name)

      frame_access(target_name, rest) if DISPATCHES.include?(name)
    end

    def retries?(root)
      each_node(root) { |node| return true if node.type == :retry }
      false
    end

    def assigned_by(node)
      case node.type
      when :lvasgn then [node.children[0]]
      when *COMPOUND_ASSIGNMENTS
        names = [] #: Array[Symbol]
        each_node(node.children[0]) { |child| names << child.children[0] if child.type == :lvasgn }
        names
      else []
      end
    end

    def after?(node, call)
      range = node.location&.expression or return true
      range.begin_pos >= call.location.expression.end_pos
    end

    # The values a call made with `arguments` hands on: the positional ones
    # and the values of the keyword ones.
    def argument_values(arguments)
      arguments.flat_map do |argument|
        next [argument] unless argument.type == :kwargs

        argument.children.filter_map { |pair| pair.children[1] if pair.type == :pair }
      end
    end
  end
end
