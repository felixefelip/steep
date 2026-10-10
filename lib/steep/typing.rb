module Steep
  class Typing
    class UnknownNodeError < StandardError
      attr_reader :op
      attr_reader :node

      def initialize(op, node:)
        @op = op
        @node = node
        super "Unknown node for #{op}: #{node.inspect}"
      end
    end

    class CursorContext
      attr_reader :index

      attr_reader :data

      def initialize(index)
        @index = index
      end

      def set(range, context = nil)
        if range.is_a?(CursorContext)
          range, context = range.data
          range or return
          context or return
        end

        context or raise
        return unless index

        if current_range = self.range
          if range.begin <= index && index <= range.end
            if current_range.begin <= range.begin && range.end <= current_range.end
              @data = [range, context]
            end
          end
        else
          @data = [range, context]
        end
      end

      def set_node_context(node, context)
        begin_pos = node.loc.expression.begin_pos
        end_pos = node.loc.expression.end_pos

        set(begin_pos..end_pos, context)
      end

      def set_body_context(node, context)
        case node.type
        when :class
          name_node, super_node, _ = node.children
          begin_pos = if super_node
                        super_node.loc.expression.end_pos
                      else
                        name_node.loc.expression.end_pos
                      end
          end_pos = node.loc.end.begin_pos # steep:ignore NoMethod

          set(begin_pos..end_pos, context)

        when :module
          name_node = node.children[0]
          begin_pos = name_node.loc.expression.end_pos
          end_pos = node.loc.end.begin_pos # steep:ignore NoMethod
          set(begin_pos..end_pos, context)

        when :sclass
          name_node = node.children[0]
          begin_pos = name_node.loc.expression.end_pos
          end_pos = node.loc.end.begin_pos # steep:ignore NoMethod
          set(begin_pos..end_pos, context)

        when :def, :defs
          if node.children.last
            args_node =
              case node.type
              when :def
                node.children[1]
              when :defs
                node.children[2]
              end

            body_begin_pos =
              case
              when node.loc.assignment # steep:ignore NoMethod
                # endless def
                node.loc.assignment.end_pos # steep:ignore NoMethod
              when args_node.loc.expression
                # with args
                args_node.loc.expression.end_pos
              else
                # without args
                node.loc.name.end_pos # steep:ignore NoMethod
              end

            body_end_pos =
              if node.loc.end # steep:ignore NoMethod
                node.loc.end.begin_pos # steep:ignore NoMethod
              else
                node.loc.expression.end_pos
              end

            set(body_begin_pos..body_end_pos, context)
          end

        when :block, :numblock, :itblock
          range = block_range(node)
          set(range, context)

        when :for
          _, collection, _ = node.children

          begin_pos = collection.loc.expression.end_pos
          end_pos = node.loc.end.begin_pos # steep:ignore NoMethod

          set(begin_pos..end_pos, context)
        else
          raise "Unexpected node for insert_context: #{node.type}"
        end
      end

      def block_range(node)
        case node.type
        when :block
          send_node, args_node, _ = node.children
          begin_pos = if send_node.type != :lambda && args_node.loc.expression
                        args_node.loc.expression.end_pos
                      else
                        node.loc.begin.end_pos # steep:ignore NoMethod
                      end
          end_pos = node.loc.end.begin_pos # steep:ignore NoMethod
        when :numblock, :itblock
          send_node, _ = node.children
          begin_pos = node.loc.begin.end_pos # steep:ignore NoMethod
          end_pos = node.loc.end.begin_pos # steep:ignore NoMethod
        end

        begin_pos..end_pos
      end

      def range
        range, _ = data
        range
      end

      def context
        _, context = data
        context
      end
    end

    attr_reader :source
    attr_reader :errors
    # Observations of precondition contract call sites recorded during type
    # checking: each entry is { key: "Class#method", satisfied: bool }. Used by
    # Contracts::Enforcement to decide whether a contract is enforced.
    attr_reader :contract_call_sites
    # Transitive precondition obligations: when a method's body calls a
    # contracted method via `self` and does NOT establish the required
    # `self.x`, the enclosing method inherits that requirement. Each entry is
    # { key: "Class#method" (the enclosing method), expr: Contracts::Expr }.
    # Consumed by Contracts::Runner to close preconditions over the self-call
    # graph.
    attr_reader :precondition_obligations
    # The RECEIVER TYPE observed at each contracted method's call sites, as an
    # RBS type string: `{ key: "Class#method", type: "(::Card & ::Card::Validated)" }`.
    # Contracts::Enforcement folds these into the one type every call site
    # agrees on, which becomes the method's `self_type` predicate
    # (felixefelip/steep#158). Recorded next to `contract_call_sites` and by the
    # same walk, so a site can never be counted for enforcement and missed here.
    attr_reader :contract_receiver_types
    # The type envs around each `if` node: `{ entry:, truthy:, falsy: }` keyed by
    # the `:if` node itself. The three are already computed while checking the
    # branches (`LogicTypeInterpreter#eval` runs on every condition); this keeps
    # the references instead of dropping them, so a later pass can READ what the
    # checker concluded about a condition rather than re-deriving it from the AST.
    #
    # Empty unless `record_branch_envs` — the normal check and the LSP pay
    # nothing, and the retained envs live only as long as one file's `Typing`.
    attr_reader :branch_envs
    attr_reader :typing
    attr_reader :parent
    attr_reader :parent_last_update
    attr_reader :last_update
    attr_reader :should_update
    attr_reader :contexts
    attr_reader :root_context
    attr_reader :method_calls
    # The `self` each call was made from, by the send node. A receiverless call
    # and a `self` argument are both written `self`, and which object that is
    # belongs to the frame the call sits in, not to the call — the one fact a
    # reader of the typing cannot get back from the node.
    attr_reader :call_self_types
    # What one `each` pushes on each pass: `{ block node => [{ value node =>
    # type }, …] }`, one hash per element of the collection, or nil for a loop
    # that could not be expanded. Each pass is checked in a typing of its own
    # and thrown away — the node has ONE type in the program, and these are the
    # types it has on a given pass — so this is where they are kept.
    attr_reader :iterations
    # Which arm of an `if` a push sits under the check left reachable: `{ if
    # node => :then | :else | nil }`, nil where it left both. Recorded only for
    # the conditionals `Accumulators` asks about, and per pass of a loop, since
    # each pass is checked in a typing of its own.
    attr_reader :arms
    # Collections whose contents someone vouched for, by the node that holds
    # them: a local where it was handed to a call as an argument (`{ lvar node
    # => tuple }`, for the locals `Accumulators` vouches for there), and a call
    # whose value the checker computed rather than read off its declaration
    # (`TypeConstruction#record_built_value`). What a call site keys its
    # specialization on, and what the fold takes as an operand, in place of a
    # declared type, which says nothing about what the array holds now.
    attr_reader :vouched
    # What each of those calls DECLARES it returns, for a local that holds the
    # computed tuple but goes on to be pushed onto (`Accumulators` keeps its
    # contents; a tuple type would make the push demand the first element).
    attr_reader :nominals
    # The types the locals a block body may change in place had before
    # `StringMutation` widened them, by the body; and the env each `break` was
    # reached with. What `UnrolledEach` runs an `each` from and stops it with.
    attr_reader :unwidened, :break_envs
    attr_reader :source_index
    attr_reader :cursor_context

    def initialize(source:, root_context:, parent: nil, parent_last_update: parent&.last_update, source_index: nil, cursor:, record_branch_envs: parent&.record_branch_envs? || false)
      @source = source

      @parent = parent
      @parent_last_update = parent_last_update
      @last_update = parent&.last_update || 0
      @should_update = false

      @errors = []
      @contract_call_sites = []
      @precondition_obligations = []
      @contract_receiver_types = []
      @record_branch_envs = record_branch_envs
      (@branch_envs = {}).compare_by_identity
      (@typing = {}).compare_by_identity
      @root_context = root_context
      (@method_calls = {}).compare_by_identity
      (@call_self_types = {}).compare_by_identity
      (@iterations = {}).compare_by_identity
      (@arms = {}).compare_by_identity
      (@vouched = {}).compare_by_identity
      (@nominals = {}).compare_by_identity
      (@unwidened = {}).compare_by_identity
      (@break_envs = {}).compare_by_identity

      @cursor_context = CursorContext.new(cursor)
      if root_context
        cursor_context.set(0..source.buffer.content&.size || 0, root_context)
      end

      @source_index = source_index || Index::SourceIndex.new(source: source)
    end

    def add_error(error)
      errors << error
    end

    def observe_contract_call_site(key:, satisfied:)
      contract_call_sites << { key: key, satisfied: satisfied }
    end

    def observe_precondition_obligation(key:, expr:)
      precondition_obligations << { key: key, expr: expr }
    end

    def observe_contract_receiver_type(key:, type:)
      contract_receiver_types << { key: key, type: type }
    end

    # `entry` is the env AFTER the condition is synthesized (so a pure call in the
    # condition is already registered) and BEFORE either branch narrows it — the
    # baseline a consumer diffs the surviving branch against.
    def record_branch_envs(node, entry:, truthy:, falsy:)
      return unless record_branch_envs?

      branch_envs[node] = { entry: entry, truthy: truthy, falsy: falsy }
    end

    def record_branch_envs?
      @record_branch_envs
    end

    def add_typing(node, type, _context)
      typing[node] = type
      @last_update += 1

      type
    end

    def add_call(node, call, self_type:)
      method_calls[node] = call
      call_self_types[node] = self_type

      call
    end

    def add_iterations(node, passes)
      iterations[node] = passes
    end

    def iterations_of(node:)
      iterations.fetch(node) { parent&.iterations_of(node: node) }
    end

    def add_arm(node, arm)
      arms[node] = arm
    end

    def arm_of(node:)
      arms.fetch(node) { parent&.arm_of(node: node) }
    end

    def add_unwidened(node, types)
      unwidened[node] = types
    end

    def unwidened_of(node:)
      unwidened.fetch(node) { parent&.unwidened_of(node: node) }
    end

    def add_break_env(node, env)
      break_envs[node] = env
    end

    def break_env_of(node:)
      break_envs[node]
    end

    def add_vouched(node, type)
      vouched[node] = type
    end

    def vouched_of(node:)
      vouched.fetch(node) { parent&.vouched_of(node: node) }
    end

    def add_nominal(node, type)
      nominals[node] = type
    end

    def nominal_of(node:)
      nominals.fetch(node) { parent&.nominal_of(node: node) }
    end

    def has_type?(node)
      typing.key?(node)
    end

    def type_of(node:)
      type = typing[node]

      if type
        type
      else
        if parent
          parent.type_of(node: node)
        else
          raise UnknownNodeError.new(:type, node: node)
        end
      end
    end

    def call_of(node:)
      call = method_calls[node]

      if call
        call
      else
        if parent
          parent.call_of(node: node)
        else
          raise UnknownNodeError.new(:call, node: node)
        end
      end
    end

    # The type `self` had where `node` was called, or nil for a node this typing
    # recorded no call for.
    def self_type_of_call(node:)
      call_self_types.fetch(node) { parent&.self_type_of_call(node: node) }
    end

    def block_range(node)
      case node.type
      when :block
        send_node, args_node, _ = node.children
        begin_pos = if send_node.type != :lambda && args_node.loc.expression
                      args_node.loc.expression.end_pos
                    else
                      node.loc.begin.end_pos # steep:ignore NoMethod
                    end
        end_pos = node.loc.end.begin_pos # steep:ignore NoMethod
      when :numblock, :itblock
        send_node, _ = node.children
        begin_pos = node.loc.begin.end_pos # steep:ignore NoMethod
        end_pos = node.loc.end.begin_pos # steep:ignore NoMethod
      end

      begin_pos..end_pos
    end

    def dump(io)
      # steep:ignore:start
      io.puts "Typing: "
      nodes.each_value do |node|
        io.puts "  #{Typing.summary(node)} => #{type_of(node: node).inspect}"
      end

      io.puts "Errors: "
      errors.each do |error|
        io.puts "  #{Typing.summary(error.node)} => #{error.inspect}"
      end
      # steep:ignore:end
    end

    def self.summary(node)
      src = node.loc.expression.source.split(/\n/).first
      line = node.loc.first_line
      col = node.loc.column

      "#{line}:#{col}:#{src}"
    end

    def new_child()
      child = self.class.new(
        source: source,
        parent: self,
        root_context: root_context,
        source_index: source_index.new_child,
        cursor: cursor_context.index,
        record_branch_envs: record_branch_envs?
      )
      @should_update = true

      if block_given?
        yield child
      else
        child
      end
    end

    def each_typing(&block)
      typing.each(&block)
    end

    def save!
      raise "Unexpected save!" unless parent
      raise "Parent modified since #new_child: parent.last_update=#{parent.last_update}, parent_last_update=#{parent_last_update}" unless parent.last_update == parent_last_update

      each_typing do |node, type|
        parent.add_typing(node, type, nil)
      end

      parent.method_calls.merge!(method_calls)
      parent.call_self_types.merge!(call_self_types)
      parent.iterations.merge!(iterations)
      parent.arms.merge!(arms)
      parent.vouched.merge!(vouched)
      parent.nominals.merge!(nominals)
      parent.branch_envs.merge!(branch_envs)

      errors.each do |error|
        parent.add_error error
      end

      contract_call_sites.each do |observation|
        parent.observe_contract_call_site(**observation)
      end

      precondition_obligations.each do |obligation|
        parent.observe_precondition_obligation(**obligation)
      end

      contract_receiver_types.each do |observation|
        parent.observe_contract_receiver_type(**observation)
      end

      parent.cursor_context.set(cursor_context)

      parent.source_index.merge!(source_index)
    end
  end
end
