module Steep
  module Postconditions
    # Walks the typed AST of a Ruby source and proposes
    # `unconditional.ivars` postcondition entries for methods that assign
    # an instance variable to a type strictly narrower than the variable's
    # RBS declaration.
    #
    # Symmetric to `Steep::Contracts::Inferrer` (preconditions). Where
    # the contracts inferrer reads diagnostic output to surface required
    # callsite checks, the postcondition inferrer reads the method body
    # itself and surfaces side effects that refine the caller's view.
    #
    # MVP heuristic:
    #
    #   - Walk every `:def` inside a class/module body.
    #   - For each def, collect all `:ivasgn` nodes in the body. If an
    #     ivar is assigned more than once, the LAST write wins (linear
    #     flow assumption; conditional assigns are handled conservatively
    #     by relying on Steep's own type at the assignment node).
    #   - For each ivar, look up the *declared* type in the class's RBS
    #     definition. If the RHS type is a strict subtype, emit the
    #     refinement.
    #   - Methods whose def is inside a singleton (`def self.x`) emit a
    #     singleton entry; everything else is an instance entry.
    class Inferrer
      include TypedNodeUtils

      def self.infer(source, typing, subtyping)
        new(source, typing, subtyping).infer
      end

      def initialize(source, typing, subtyping)
        @source = source
        @typing = typing
        @subtyping = subtyping
        @factory = subtyping.factory
        @definition_builder = subtyping.factory.definition_builder
        @return_establishment_inferrer = ReturnEstablishmentInferrer.new(typing, subtyping)
        # Empty unless the type check ran with `record_branch_envs: true`; the
        # guard collector falls back to reading the AST when it is.
        @branch_envs = typing.branch_envs
      end

      def infer
        return [] unless @source.node

        results = []
        walk_classes(@source.node, nesting: []) do |def_node, class_name, singleton|
          ivars = collect_ivar_refinements(def_node, class_name, singleton: singleton)
          when_true_ivars = collect_when_true_nonnil_refinements(def_node, class_name, singleton: singleton)
          returns_establishes = @return_establishment_inferrer.establishments(def_node)
          may_write = collect_ivar_writes(def_node, class_name, singleton: singleton)
          self_call_deps = collect_self_call_deps(def_node)
          unconditional_call_deps = collect_unconditional_call_deps(def_node)
          when_true_consts, when_true_call_deps = collect_when_true_facts(def_node)
          disjunction_chains = collect_disjunction_operands(def_node)
          when_true_block_truthy, block_forward_deps = collect_block_truthy(def_node)
          returns_ivar = collect_returns_ivar(def_node, class_name, singleton: singleton)
          conditional_returns = collect_conditional_returns(def_node, class_name, singleton: singleton)
          conditional_const_returns = collect_conditional_const_returns(def_node)
          const_establishments = collect_const_establishments(def_node)
          establishes_consts = collect_establishes_consts(def_node, singleton: singleton)
          delegates_to_instance = singleton_delegates_to_instance?(def_node, class_name, singleton: singleton)
          # `unconditional_call_deps` is deliberately NOT part of this condition,
          # unlike `self_call_deps`. Its receiver is unrestricted, so `1 + 2` is an
          # edge (`Integer#+`) and counting it would mint an entry for practically
          # every method in a project, only for `empty?` to drop them all after the
          # fixpoint — with the closures paying for them in between. A self-call
          # edge already keeps a caller alive, which covers every unconditional dep
          # that is a self-send; a caller whose ONLY content is an establishing call
          # on ANOTHER object gets no entry, and so lifts nothing (felixefelip/steep#117).
          # `block_forward_deps` keeps an entry alive though it states nothing
          # yet: a pure forwarder (`def authenticate_with_http_token(&p);
          # Token.authenticate(self, &p); end`) is the middle of the chain, and
          # dropping it before the fixpoint breaks the link it exists to carry.
          # Unlike `unconditional_call_deps` this costs little — the edge only
          # exists when a method's VALUE is a call it also handed its block to.
          if ivars.empty? && when_true_ivars.empty? && returns_establishes.empty? &&
             may_write.empty? && self_call_deps.empty? && returns_ivar.nil? &&
             conditional_returns.empty? && conditional_const_returns.empty? &&
             establishes_consts.empty? && const_establishments.empty? && !delegates_to_instance &&
             !when_true_block_truthy && block_forward_deps.empty?
            next
          end

          method_name = def_node.children[0]
          self_type_string = marker_self_type_for(class_name, method_name, singleton: singleton) unless ivars.empty?
          when_true_self_type_string = marker_self_type_for(class_name, method_name, singleton: singleton) unless when_true_ivars.empty?

          results << InferredEntry.new(
            class_name: class_name,
            method_name: method_name,
            singleton: singleton,
            ivars: ivars,
            self_type_string: self_type_string,
            when_true_ivars: when_true_ivars,
            when_true_self_type_string: when_true_self_type_string,
            returns_establishes: returns_establishes,
            may_write_ivars: may_write,
            self_call_deps: self_call_deps,
            unconditional_call_deps: unconditional_call_deps,
            when_true_consts: when_true_consts,
            when_true_call_deps: when_true_call_deps,
            disjunction_chains: disjunction_chains,
            when_true_block_truthy: when_true_block_truthy,
            block_forward_deps: block_forward_deps,
            returns_ivar: returns_ivar,
            conditional_returns: conditional_returns,
            conditional_const_returns: conditional_const_returns,
            establishes_consts: establishes_consts,
            const_establishments: const_establishments,
            delegates_to_instance: delegates_to_instance
          )
        end
        results
      end

      private

      # Composes the `unconditional.self:` value for an inferred entry,
      # following the `MarkerNaming` convention shared with rbs_infer.
      # Instance methods get `"::ClassName & ::ClassName::AfterMethod"`
      # so consumers (`apply_unconditional_postconditions`) can REPLACE
      # the receiver's type with the intersection. Singleton methods
      # don't get a marker — there's no established convention for
      # narrowing a class/module value, and the inferrer for those is
      # rare in practice. Method names that strip to empty under
      # `pascal_case` (e.g. `:"="`) are also skipped.
      def marker_self_type_for(class_name, method_name, singleton:)
        return nil if singleton
        return nil unless MarkerNaming.valid_method_name?(method_name)
        MarkerNaming.narrowed_self_type_for(class_name, method_name)
      end

      # Walks the AST yielding (def_node, class_name, singleton?) for each
      # method definition found inside a class/module. Skips top-level
      # `def`s (no class to attach a postcondition to).
      def walk_classes(node, nesting:, &block)
        return unless node.is_a?(Parser::AST::Node)

        case node.type
        when :class
          const_node, _super, body = node.children
          name = extract_const_name(const_node)
          new_nesting = name ? nesting + [name] : nesting
          walk_classes(body, nesting: new_nesting, &block) if body
        when :module
          const_node, body = node.children
          name = extract_const_name(const_node)
          new_nesting = name ? nesting + [name] : nesting
          walk_classes(body, nesting: new_nesting, &block) if body
        when :def
          yield node, nesting.join("::"), false unless nesting.empty?
        when :defs
          receiver, _name, _args, _body = node.children
          if receiver&.type == :self && !nesting.empty?
            # Reshape `(:defs (self) name args body)` as `(:def name args body)`
            # so downstream code can read children[0] uniformly.
            shaped = node.updated(:def, node.children.drop(1))
            yield shaped, nesting.join("::"), true
          end
        when :begin, :kwbegin
          node.children.each { |child| walk_classes(child, nesting: nesting, &block) }
        when :sclass
          # `class << self`: the body's `def x` is a singleton method on
          # the surrounding constant. Recurse with a flag.
          body = node.children[1]
          walk_singleton_body(body, nesting: nesting, &block) if body
        else
          node.children.each do |child|
            walk_classes(child, nesting: nesting, &block) if child.is_a?(Parser::AST::Node)
          end
        end
      end

      def walk_singleton_body(node, nesting:, &block)
        return unless node.is_a?(Parser::AST::Node)
        case node.type
        when :def
          yield node, nesting.join("::"), true unless nesting.empty?
        when :begin, :kwbegin
          node.children.each { |child| walk_singleton_body(child, nesting: nesting, &block) }
        end
      end

      def extract_const_name(node)
        return nil unless node.is_a?(Parser::AST::Node)
        case node.type
        when :const
          parent, name = node.children
          parent_name = parent ? extract_const_name(parent) : nil
          parent_name ? "#{parent_name}::#{name}" : name.to_s
        end
      end

      # Returns `Hash[Symbol, AST::Types::t]` of `@ivar` to refined type,
      # populated only for ivars whose RHS type at the last assignment in
      # the body is a strict subtype of their RBS declaration.
      def collect_ivar_refinements(def_node, class_name, singleton:)
        body = def_node.children[2]
        return {} unless body

        last_writes = {} #: Hash[Symbol, AST::Types::t]
        walk_ivasgns(body) do |ivasgn_node|
          name = ivasgn_node.children[0]
          rhs_node = ivasgn_node.children[1]
          next unless rhs_node
          rhs_type = intrinsic_type_of(rhs_node)
          next unless rhs_type
          last_writes[name] = rhs_type
        end
        return {} if last_writes.empty?

        declared_types = declared_ivar_types(class_name, singleton: singleton)
        last_writes.each_with_object({}) do |(name, rhs_type), result|
          declared = declared_types[name]
          next unless declared
          next unless strict_subtype?(rhs_type, declared)
          result[name] = rhs_type
        end
      end

      # Returns `Hash[Symbol, AST::Types::t]` mapping `@ivar` to its
      # refined type for methods whose body, when evaluated by the
      # `LogicTypeInterpreter`, narrows one or more ivars in the
      # truthy branch.
      #
      # Defers all shape recognition to the same logical-type
      # machinery Steep uses for `if`/`unless`/`&&`/`||` narrowing —
      # so `!@x.nil?`, `@x.is_a?(Klass)` and any future Logic-type
      # patterns are picked up uniformly, without re-implementing
      # the case analysis here.
      #
      # The interpreter runs against a fresh env populated only with
      # the class's declared instance variables; the result's truthy
      # env is compared to that baseline. Ivar entries that ended up
      # strictly narrower (declared `T?` → refined `T`) become
      # postcondition refinements. Equal entries are dropped — a
      # no-op refinement would only add sidecar noise.
      def collect_when_true_nonnil_refinements(def_node, class_name, singleton:)
        body = def_node.children[2]
        return {} unless body
        last_expr = last_expression(body) or return {}

        return {} unless predicate_body?(last_expr)

        env = build_env_for_class(class_name, singleton: singleton) or return {}
        interpreter = build_interpreter_for_class(class_name, singleton: singleton)
        return {} unless interpreter

        truthy_result = nil
        begin
          truthy_result = evaluate_truthy(interpreter: interpreter, env: env, node: last_expr)
        rescue StandardError => e
          Steep.logger.warn { "[postconditions] when_true inference failed for #{class_name}##{def_node.children[0]}: #{e.message}" }
          return {}
        end
        return {} unless truthy_result
        return {} if truthy_result.unreachable

        declared = declared_ivar_types(class_name, singleton: singleton)
        refined_ivars = truthy_result.env.instance_variable_types
        refined_ivars.each_with_object({}) do |(name, refined_type), result|
          declared_type = declared[name]
          next unless declared_type
          next if refined_type == declared_type
          next unless strict_subtype?(refined_type, declared_type)
          result[name] = refined_type
        end
      end

      # Returns the LogicTypeInterpreter `Result` for the truthy
      # branch of `node`, handling `:and`/`:or` by composition.
      # The interpreter natively dispatches on `:send` /
      # `Logic::Env`-typed nodes, but method bodies aren't
      # type-checked in conditional mode, so `:and`/`:or` nodes
      # carry plain Boolean types and the interpreter's default
      # path would refine nothing. Walking them here threads the
      # truthy env from the left side into the right side's
      # evaluation, matching what `type_construction.rb`'s `:and`
      # handler does during real conditional type-checking.
      def evaluate_truthy(interpreter:, env:, node:)
        case node.type
        when :and
          left_truthy = evaluate_truthy(interpreter: interpreter, env: env, node: node.children[0])
          return nil unless left_truthy
          return left_truthy if left_truthy.unreachable
          evaluate_truthy(interpreter: interpreter, env: left_truthy.env, node: node.children[1])
        else
          truthy_result, _falsy_result = interpreter.eval(env: env, node: node)
          truthy_result
        end
      end

      # Whether `node` is or recursively contains a logic-typed
      # sub-expression (`Logic::Base` / `Logic::Env`) the interpreter
      # can derive a narrowing from. Method bodies aren't
      # type-checked in conditional mode, so `:and`/`:or` operators
      # carry plain Boolean — recursing into their operands is the
      # only way to spot a nil-check buried inside `a && b`.
      def predicate_body?(node)
        case node&.type
        when :and, :or
          predicate_body?(node.children[0]) || predicate_body?(node.children[1])
        else
          type = type_of(node)
          return false unless type
          type.is_a?(AST::Types::Logic::Base) || type.is_a?(AST::Types::Logic::Env)
        end
      end

      # Minimal env with just the class's declared instance variables
      # populated, scoped to a fresh `ConstantEnv`. The interpreter
      # mutates the env on refinement; we compare the result against
      # the same baseline to surface only the differences.
      def build_env_for_class(class_name, singleton:)
        ivars = declared_ivar_types(class_name, singleton: singleton)
        return nil if ivars.empty?

        const_env = TypeInference::ConstantEnv.new(
          factory: @factory,
          context: nil,
          resolver: RBS::Resolver::ConstantResolver.new(builder: @factory.definition_builder)
        )
        env = TypeInference::TypeEnv.new(const_env)
        env.refine_types(instance_variable_types: ivars)
      end

      def build_interpreter_for_class(class_name, singleton:)
        type_name = RBS::TypeName.parse("::#{class_name}").absolute! rescue nil
        return nil unless type_name

        instance_type =
          if singleton
            AST::Types::Name::Singleton.new(name: type_name)
          else
            AST::Types::Name::Instance.new(name: type_name, args: [])
          end
        class_type = AST::Types::Name::Singleton.new(name: type_name)

        config = Interface::Builder::Config.new(
          self_type: instance_type,
          class_type: class_type,
          instance_type: instance_type,
          variable_bounds: {}
        )

        TypeInference::LogicTypeInterpreter.new(
          subtyping: @subtyping,
          typing: @typing,
          config: config,
          self_type: instance_type
        )
      end

      # felixefelip/steep#68 (item 1), the EFFECT side of the inference.
      #
      # Every declared ivar the body assigns — anywhere, including inside a
      # block it passes to someone else (`respond_to { |f| f.html { @x = 1 } }`),
      # since a block body runs in this same `self`. Unlike
      # `collect_ivar_refinements` this records no type: it is a MAY-write, used
      # by the caller only to drop a now-stale narrowing.
      def collect_ivar_writes(def_node, class_name, singleton:)
        body = def_node.children[2]
        return Set[] unless body

        declared = declared_ivar_types(class_name, singleton: singleton)
        writes = Set.new #: Set[Symbol]
        walk_ivasgns(body) do |ivasgn_node|
          name = ivasgn_node.children[0]
          writes << name if declared.key?(name)
        end
        writes
      end

      # The self-sends of the body, as `"Class#method"` keys — the edges of the
      # call graph the Runner closes over, so that a method whose only "write" is
      # a call to something that writes (`authenticate_user` -> `redirect_to`)
      # still reports the effect.
      #
      # Only self-sends: an ivar write inside `other.foo` mutates OTHER's ivars,
      # not ours. The callee's OWNER comes from the typed call (`method_decls`),
      # so an inherited method resolves to the class that declares it
      # (`redirect_to` -> `ActionController::Base`), which is how the store is
      # keyed.
      def collect_self_call_deps(def_node)
        body = def_node.children[2]
        return Set[] unless body

        deps = Set.new #: Set[String]
        walk_sends(body) do |send_node|
          receiver = send_node.children[0]
          next unless receiver.nil? || receiver.type == :self

          call = @typing.call_of(node: send_node) rescue nil
          next unless call.is_a?(TypeInference::MethodCall::Typed)

          call.method_decls.each do |decl|
            method_name = decl.method_name
            next unless method_name.respond_to?(:type_name)

            owner = method_name.type_name.to_s.sub(/\A::/, "")
            deps << "#{owner}##{method_name.method_name}"
          end
        end
        deps
      end

      # felixefelip/steep#117 gap 3a. The `"Owner#method"` of the calls this method
      # makes on EVERY exit, so the Runner can lift what those callees establish
      # into this method's own `const_establishments`. Without it an establishment
      # stops at the frame that performs the write — `Current.session =` lives in
      # `set_current_session`, and the caller one frame up proved nothing.
      #
      # This is NOT a subset of `self_call_deps`; it differs on both axes:
      #
      #   * Only TOP-LEVEL statements count, the same boundary
      #     `collect_const_establishments` draws and for the same reason — a call
      #     inside an `if` runs on some exits and not others. `self_call_deps` uses
      #     `walk_sends` (any depth, block bodies included), which is right for
      #     "may write" and wrong for "does establish". A method that can halt
      #     contributes nothing at all: past the halt the rest is unreached.
      #   * The RECEIVER is unrestricted. A constant is global state, so
      #     `Registry.new.populate` establishes `Registry.thing` exactly as a
      #     self-send would — the same reason
      #     `Runner#apply_call_const_establishments` is not same-self gated, unlike
      #     the ivar effects beside it.
      def collect_unconditional_call_deps(def_node)
        body = def_node.children[2]
        return Set[] unless body
        return Set[] if method_halt_gate(body)

        deps = Set.new #: Set[String]
        each_statement(body) do |stmt|
          send_node = unconditional_send(stmt) or next
          collect_call_keys(send_node, deps)
        end
        deps
      end

      # The `"Owner#method"` keys a call resolves to, added to `deps`. The owner
      # comes from the typed call, so an inherited method resolves to the class
      # that declares it — which is how the entry store is keyed.
      def collect_call_keys(send_node, deps)
        call = @typing.call_of(node: send_node) rescue nil
        return unless call.is_a?(TypeInference::MethodCall::Typed)

        call.method_decls.each do |decl|
          method_name = decl.method_name
          next unless method_name.respond_to?(:type_name)

          owner = method_name.type_name.to_s.sub(/\A::/, "")
          deps << "#{owner}##{method_name.method_name}"
        end
      end

      # felixefelip/steep#117 gap 3b. What the method establishes on its TRUTHY
      # exit only — the const counterpart of `when_true_ivars`.
      #
      #   def resume_session
      #     if session = find_session_by_cookie
      #       set_current_session session      # establishes Current.session
      #     end
      #   end
      #
      # Returns `[writes, call_deps]`: the constant writes the clause performs at
      # its own top level, and the calls it makes there — the latter being the
      # common case, since the establishing write usually lives one frame down
      # (the Runner resolves them against what those callees establish).
      #
      # Soundness does NOT require the clause's value to be truthy. What matters
      # is that every OTHER way out is falsy, so a truthy return can only have
      # come from the clause. Hence the three requirements:
      #
      #   * the `if` is the method's LAST statement — anything after it decides
      #     the return value instead;
      #   * it has exactly ONE clause. `if c; A; end` and `unless c; A; end` both
      #     qualify (the missing branch is an implicit `nil`); an `else` gives a
      #     second way to produce a truthy value;
      #   * the method contains no `return`, which would be a third.
      def collect_when_true_facts(def_node)
        body = def_node.children[2]
        return [{}, Set[]] unless body
        return [{}, Set[]] if contains_return?(body)

        clause = truthy_only_clause(body) or return [{}, Set[]]

        writes = {} #: Hash[String, untyped]
        deps = Set.new #: Set[String]

        each_statement(clause) do |stmt|
          if (write = const_attr_write(stmt))
            const_path, rhs = write
            next if writes.key?(const_path)

            type = nonnil_value_type(rhs) or next
            writes[const_path] = type
          elsif (send_node = unconditional_send(stmt))
            collect_call_keys(send_node, deps)
          end
        end

        [writes, deps]
      end

      # felixefelip/rbs_infer#144 stage 2. Whether a truthy return of this method
      # can only have come from its BLOCK answering truthy.
      #
      #   def authenticate(controller, &login_procedure)
      #     token, options = token_and_options(controller.request)
      #     unless token.blank?
      #       login_procedure.call(token, options)   # the method's value IS the block's
      #     end
      #   end
      #
      # This is the link a caller needs before it can believe anything the block
      # established: `foo { Current.identity = identity }` returning truthy says
      # the block ran AND answered truthy, so the block's own facts hold. Without
      # it the block is a wall — what happens inside is invisible to the caller,
      # which is the whole reason felixefelip/rbs_infer#144 exists.
      #
      # Returns `[proven, forward_deps]`. Proven when the method's value is the
      # block's own call; otherwise the calls that value is FORWARDED to together
      # with the block (`Token.authenticate(self, &login_procedure)`), which the
      # Runner closes over — the fact travels a delegation chain the same way
      # `when_true_call_deps` does.
      #
      # A `return` anywhere disqualifies the method, as it does for
      # `when_true_consts`: the last statement is no longer what a truthy exit
      # returned.
      def collect_block_truthy(def_node)
        body = def_node.children[2]
        return [false, Set[]] unless body
        return [false, Set[]] if contains_return?(body)

        value = returned_value(body) or return [false, Set[]]
        block_name = block_param_name(def_node)

        return [true, Set[]] if block_value?(value, block_name)

        deps = Set.new #: Set[String]
        collect_call_keys(value, deps) if forwards_block?(value, block_name)
        [false, deps]
      end

      # The expression a truthy exit returned: the body's last statement, or —
      # when that is a one-armed `if` — the clause's own last statement. The
      # guard only adds a FALSY way out (`unless token.blank?` yields nil), which
      # cannot weaken a fact about a truthy return.
      def returned_value(body)
        last = last_statement(body)
        return nil unless last

        if last.type == :if && (clause = truthy_only_clause(body))
          last_statement(clause)
        else
          last
        end
      end

      def last_statement(node)
        found = nil #: Parser::AST::Node?
        each_statement(node) { |stmt, is_last| found = stmt if is_last }
        found.is_a?(Parser::AST::Node) ? found : nil
      end

      def block_param_name(def_node)
        args = def_node.children[1]
        return nil unless args.is_a?(Parser::AST::Node)

        blockarg = args.children.find { |arg| arg.is_a?(Parser::AST::Node) && arg.type == :blockarg }
        blockarg&.children&.first&.to_s
      end

      # `yield`, `block.call(…)`, `block.(…)` — the block's value becoming the
      # method's.
      def block_value?(node, block_name)
        return true if node.type == :yield
        return false unless node.type == :send && node.children[1] == :call

        reads_block?(node.children[0], block_name)
      end

      # `callee(&block)` in value position: this method's answer is the callee's,
      # and the block it answered with is ours.
      def forwards_block?(node, block_name)
        return false unless node.type == :send

        node.children.any? do |child|
          child.is_a?(Parser::AST::Node) && child.type == :block_pass &&
            reads_block?(child.children[0], block_name)
        end
      end

      def reads_block?(node, block_name)
        block_name && node.is_a?(Parser::AST::Node) && node.type == :lvar &&
          node.children[0].to_s == block_name
      end

      # The single clause of a body whose last statement is a one-armed `if`, or
      # nil when the body has another way to return truthy.
      def truthy_only_clause(body)
        last = nil #: Parser::AST::Node?
        each_statement(body) { |stmt, is_last| last = stmt if is_last }
        return nil unless last.is_a?(Parser::AST::Node) && last.type == :if

        _cond, true_clause, false_clause = last.children
        return nil unless true_clause.nil? ^ false_clause.nil?

        true_clause || false_clause
      end

      def contains_return?(node)
        return false unless node.is_a?(Parser::AST::Node)
        return true if node.type == :return

        node.children.any? { |child| contains_return?(child) }
      end

      # The call a top-level statement makes unconditionally: the statement IS the
      # send (`set_current_session session`), or it assigns the send's result
      # (`ok = set_current_session session`, `@ok = …`). `&.` is refused in either
      # position, since `x&.establish` does not run when `x` is nil.
      def unconditional_send(stmt)
        return nil unless stmt.is_a?(Parser::AST::Node)

        node =
          case stmt.type
          when :send then stmt
          when :lvasgn, :ivasgn, :gvasgn, :cvasgn then stmt.children[1]
          when :casgn then stmt.children[2]
          end

        node.is_a?(Parser::AST::Node) && node.type == :send ? node : nil
      end

      # felixefelip/steep#68 (item 2), the halt-check link. A method whose body
      # is a single instance-variable read (`def performed?; @halted; end`) is a
      # transparent getter of that ivar: testing it (`return if performed?`) must
      # narrow the ivar, just as `attr_reader` already does. Returns the ivar
      # name or nil.
      def collect_returns_ivar(def_node, class_name, singleton:)
        body = def_node.children[2]
        return nil unless body

        expr = last_expression(body)
        return nil unless expr&.type == :ivar

        name = expr.children[0]
        declared_ivar_types(class_name, singleton: singleton).key?(name) ? name : nil
      end

      # felixefelip/steep#68 (item 2), the positive proof. Recognises a guard
      # clause that aborts unless a nilable self-method is present:
      #
      #   def authenticate_user
      #     unless current_user      # `if !current_user` too
      #       redirect_to root_path  # writes a may-write ivar => halts
      #       return
      #     end
      #     ...
      #   end
      #
      # On the exit that did NOT halt, `current_user` is proven non-nil. That
      # fact is gated by the ivar the halting branch writes (`@halted`): a caller
      # sees it only where that ivar is known falsy — which is exactly what
      # `return if performed?` establishes (via `returns_ivar`).
      #
      # => Hash[Symbol(method), { gate_ivar: Symbol?, gate_via: Symbol?, type: }]
      # The gate is expressed as either the ivar the abort clause writes directly
      # (`gate_ivar`) OR the self-method it calls to halt (`gate_via`, e.g.
      # `redirect_to`) — the Runner resolves `gate_via` to the ivar that method
      # actually writes, once the may-write closure is known.
      def collect_conditional_returns(def_node, class_name, singleton:)
        body = def_node.children[2]
        return {} unless body

        result = {} #: Hash[Symbol, untyped]
        each_guard_fact(body) do |fact, gate|
          method = fact[:self_method] or next
          next if result.key?(method)

          nonnil = nonnil_return_of_self_method(method, class_name, singleton: singleton) or next
          result[method] = gate.merge(type: nonnil)
        end
        result
      end

      # Yields `[fact, gate]` for every fact every top-level guard clause proves.
      # The two collectors share the walk and each keeps the facts it owns.
      def each_guard_fact(body)
        each_statement(body) do |stmt, terminal|
          guard = negative_presence_guard(stmt, terminal: terminal) or next
          facts, gate = guard
          facts.each { |fact| yield fact, gate }
        end
      end

      # felixefelip/steep#68 (item 3) — the constant-rooted proof. A guard that
      # halts, then writes a non-nil value to a constant attribute:
      #
      #   def authenticate_user
      #     unless current_user
      #       redirect_to        # halts => gate @performed
      #       return
      #     end
      #     Current.user = current_user   # top-level, non-nil (past the guard)
      #   end
      #
      # proves `Current.user` non-nil on the unhalted exit, gated by the same
      # halt ivar as the self-method case. Keyed by the `"Const.attr"` path.
      #
      # felixefelip/steep#105 gap 1 adds the other half: a guard that TESTS the
      # constant proves it just as well, with no write anywhere:
      #
      #   def ensure_access
      #     unless Current.user
      #       redirect_to
      #       return
      #     end
      #   end
      #
      # That is the commoner of the two — a guard normally asserts what someone
      # else already populated, which is what an authorization callback does —
      # and it used to prove nothing at all, because the collector only ever
      # looked at writes.
      #
      # => Hash[String, { gate_ivar: Symbol?, gate_via: Symbol?, type: }]
      def collect_conditional_const_returns(def_node)
        body = def_node.children[2]
        return {} unless body

        result = {} #: Hash[String, untyped]

        # Writes first: a write is more specific than a test, since it carries
        # the written value's own type rather than the declaration's.
        if (gate = method_halt_gate(body))
          each_statement(body) do |stmt|
            write = const_attr_write(stmt) or next
            const_path, rhs = write
            next if result.key?(const_path)

            type = nonnil_value_type(rhs) or next
            result[const_path] = gate.merge(type: type)
          end
        end

        # felixefelip/rbs_infer#144. A two-clause `if` where one side ESTABLISHES
        # and the other HALTS:
        #
        #   if token?
        #     Current.identity = identity      # establishes
        #   else
        #     request_http_token_authentication # halts
        #   end
        #
        # Leaving the method without having halted means the establishing clause
        # ran — the same "unhalted exit" the gate above expresses, so it keys the
        # same slot. No other collector here covers it: the one-armed guard shapes
        # are `method_halt_gate`'s business, and `when_true_consts` refuses a
        # two-clause `if` precisely because a truthy return no longer says which
        # clause ran. A halt is what distinguishes the two branches, and that is
        # what makes this provable where truthiness was not.
        each_halting_alternative(body) do |establishing, gate|
          each_statement(establishing) do |stmt|
            write = const_attr_write(stmt) or next
            const_path, rhs = write
            next if result.key?(const_path)

            type = nonnil_value_type(rhs) or next
            result[const_path] = gate.merge(type: type)
          end
        end

        each_guard_fact(body) do |fact, gate|
          const_path = fact[:const_path] or next
          next if result.key?(const_path)

          const_name, attr = const_path.split(".", 2)
          next unless const_name && attr
          # The attribute is a singleton method of the constant, so its declared
          # return type — minus nil — is what the test proves. `nil` back means
          # the declaration was not nilable to begin with: nothing to prove.
          nonnil = nonnil_return_of_self_method(attr.to_sym, const_name, singleton: true) or next
          result[const_path] = gate.merge(type: nonnil)
        end

        result
      end

      # felixefelip/steep#100. The UNCONDITIONAL sibling of
      # `collect_conditional_const_returns`: a method whose body cannot halt writes its
      # constant attributes on every exit, so they need no gate.
      #
      #   def set_current_account
      #     Current.account = current_account   # non-nil at entry, past the guard
      #   end
      #
      # A `before_action` handler that populates global state is the shape this exists for.
      # It used to prove nothing at all — `conditional_const_returns` needs a halt gate to
      # key its facts on, and a plain handler has none, so the establishment stopped at the
      # handler's own body and reached neither the action nor the view it renders.
      #
      # Only emitted when there is NO halt gate, so the two collectors partition rather
      # than double-report. Sound because `each_statement` yields the body's TOP-LEVEL
      # statements only: a write nested in an `if` is invisible here, and stays that way.
      #
      # => Hash[String("Const.attr"), AST::Types::t]
      def collect_const_establishments(def_node)
        body = def_node.children[2]
        return {} unless body
        return {} if method_halt_gate(body)

        result = {} #: Hash[String, untyped]
        each_statement(body) do |stmt|
          write = const_attr_write(stmt) or next
          const_path, rhs = write
          next if result.key?(const_path)

          type = nonnil_value_type(rhs) or next
          result[const_path] = type
        end
        result
      end

      # felixefelip/steep#68 item 5, the establishment side. For an INSTANCE
      # setter (`def user=(value)`), the other constant attributes its body
      # establishes non-nil, given its argument is non-nil:
      #
      #   def user=(value)
      #     super(value)
      #     self.author_name = value&.full_name   # => establishes author_name
      #   end
      #
      # `value&.full_name` is non-nil when `value` is (the safe-nav's only nil
      # source), so setting `user` to a non-nil value sets `author_name` too.
      # Keyed by attribute name; the Runner promotes these to the constant
      # (`Current.author_name`) at each `Current.user = <non-nil>` write site.
      #
      # The sibling's right-hand side may also read the attribute BEING SET
      # instead of the param (`self.identity = session.identity` inside
      # `def session=`), which is the ordinary way to write a `CurrentAttributes`
      # override — see `own_attr_guarded_nonnil_type` (felixefelip/steep#117).
      # => Hash[Symbol(attr), AST::Types::t]
      def collect_establishes_consts(def_node, singleton:)
        return {} unless def_node.children[0].to_s.end_with?("=") && def_node.children[0] != :==

        param = setter_param_name(def_node) or return {}
        body = def_node.children[2] or return {}

        result = {} #: Hash[Symbol, untyped]

        # The param's non-nil type when the setter writes its OWN backing with the
        # bare param. Computed FIRST because it does double duty: it is the
        # own-attribute establishment recorded at the bottom, and it is the licence
        # for the sibling establishment to read the attribute rather than the param.
        own_attr = def_node.children[0].to_s.chomp("=").to_sym
        own_type = own_attribute_establishment_type(body, param, own_attr)

        # Side-effect establishments — `self.<other> = <param>.<method>` writes a
        # SIBLING attribute non-nil whenever the param is. Instance setters only:
        # in a singleton body `self` is the class, so `self.<other> =` would key
        # a different (singleton) attribute the runner's delegation gate doesn't
        # cover.
        unless singleton
          walk_nodes(body) do |n|
            write = self_attr_write(n) or next
            attr, rhs = write
            type = param_guarded_nonnil_type(rhs, param) ||
                   own_attr_guarded_nonnil_type(rhs, own_attr, own_type)
            next unless type
            result[attr] = type
          end
        end

        # Own-attribute establishment — a setter `<attr>=` that writes its OWN
        # backing with the (non-nil) param, via `super(<param>)` / bare `super`,
        # `@<attr> = <param>`, or `self.<attr> = <param>`. Establishes `<attr>`
        # at the param's non-nil type. Sound for both instance (delegated) and
        # singleton setters because the consumer gates each establishment on the
        # ACTUAL argument being non-nil at every `Const.<attr> = ...` site — so
        # storing the non-nil type holds even when the param is declared nilable
        # (a `Const.<attr> = nil` write establishes nothing). felixefelip/steep#76.
        result[own_attr] ||= own_type if own_type

        result
      end

      # The param's non-nil type when the setter body writes its OWN attribute
      # (`own_attr`) with the bare param — `super(<param>)` / `super`,
      # `@<own_attr> = <param>`, or `self.<own_attr> = <param>` — else nil. Reads
      # the param's type off whichever typed param-lvar node is present; bare
      # `super` alone (no explicit param node to type) is not enough on its own.
      def own_attribute_establishment_type(body, param, own_attr)
        param_node = nil #: Parser::AST::Node?

        walk_nodes(body) do |n|
          case n.type
          when :super
            arg = n.children[0]
            param_node ||= arg if param_lvar?(arg, param)
          when :ivasgn
            ivar, rhs = n.children
            param_node ||= rhs if ivar == :"@#{own_attr}" && param_lvar?(rhs, param)
          when :send
            write = self_attr_write(n)
            param_node ||= write[1] if write && write[0] == own_attr && param_lvar?(write[1], param)
          end
        end

        return nil unless param_node

        type = type_of(param_node) or return nil
        return nil if type.is_a?(AST::Types::Any)
        subtract_nil(type)
      end

      def param_lvar?(node, param)
        node.is_a?(Parser::AST::Node) && node.type == :lvar && node.children[0] == param
      end

      # Whether a SINGLETON setter (`def self.user=(value)`) delegates to the
      # instance one (`instance.user = value`) over an instance of the enclosing
      # class. Only then is it sound to attribute the instance setter's
      # establishments to a `Const.user =` write.
      def singleton_delegates_to_instance?(def_node, class_name, singleton:)
        return false unless singleton
        attr = def_node.children[0].to_s
        return false unless attr.end_with?("=")
        body = def_node.children[2] or return false

        found = false
        walk_nodes(body) do |n|
          next unless n.type == :send && n.children[1].to_s == attr
          found = true if delegating_instance_receiver?(n.children[0], class_name)
        end
        found
      end

      # The receiver of a delegated setter call (`foo_instance.user = value`)
      # that stands in for an instance of the enclosing class: any memoized
      # singleton accessor (from `@foo ||= Foo.new`) whose resolved return type
      # IS an instance of `class_name`. It's the type, not the accessor's name,
      # that makes the delegation sound, so we read it off the typed node rather
      # than pattern-matching the `||=` body — a memoized accessor under any name
      # is recognized.
      #
      # Recognition is purely by return type; no accessor name is special-cased.
      # A singleton accessor typed as the concrete class is recognized; one whose
      # RBS return type is `untyped` (as some framework accessors are) is not,
      # which is correct — the caller is expected to expose a typed accessor.
      def delegating_instance_receiver?(recv, class_name)
        return false unless recv.is_a?(Parser::AST::Node)
        return false unless recv.type == :send && recv.children[0].nil?

        recv_type = type_of(recv) or return false
        target = "::#{class_name}"
        instance_type_names(subtract_nil(recv_type)).any? { |name| name.to_s == target }
      end

      def setter_param_name(def_node)
        args = def_node.children[1]
        req = args&.children&.find { |a| a.is_a?(Parser::AST::Node) && a.type == :arg }
        req&.children&.first
      end

      # `self.<attr> = <rhs>` => `[attr_sym, rhs_node]`, else nil.
      def self_attr_write(node)
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :send

        method = node.children[1].to_s
        return nil unless method.end_with?("=") && node.children[1] != :==

        receiver = node.children[0]
        return nil unless receiver.is_a?(Parser::AST::Node) && receiver.type == :self

        rhs = node.children[2] or return nil
        [method.chomp("=").to_sym, rhs]
      end

      # For `<param>&.<method>` / `<param>.<method>`, the method's return on the
      # param's NON-NIL type, when that return is itself non-nil (so the write
      # establishes the attribute). nil otherwise.
      def param_guarded_nonnil_type(rhs, param)
        return nil unless rhs.is_a?(Parser::AST::Node) && (rhs.type == :send || rhs.type == :csend)

        recv = rhs.children[0]
        return nil unless recv.is_a?(Parser::AST::Node) && recv.type == :lvar && recv.children[0] == param

        # Steep already typed this node under whatever narrowing holds AT it — inside
        # `unless value.nil?`, `value` is non-nil — and its dispatch handles an
        # intersection receiver properly, picking `User::Validated#name: () -> String`
        # over `User#name: () -> String?`. When that type is non-nil it IS the answer.
        #
        # The manual resolution below stays for the shape where the node's own type is
        # nilable because the READ is, not because the attribute is: `value&.full_name`
        # types as `String?` no matter how non-nil `full_name` is (felixefelip/steep#102).
        typed = type_of(rhs)
        return typed if typed && subtract_nil(typed) == typed

        recv_type = type_of(recv) or return nil
        ret = resolve_method_return(subtract_nil(recv_type), rhs.children[1]) or return nil
        subtract_nil(ret) == ret ? ret : nil
      end

      # felixefelip/steep#117. `param_guarded_nonnil_type` for the spelling that
      # reads the attribute BEING SET instead of the param:
      #
      #   def session=(value)
      #     super(value)
      #     self.identity = session.identity   # `session` IS `value` at this point
      #   end
      #
      # which is how a `CurrentAttributes` override is ordinarily written, and how
      # the app that motivated this writes it. `own_type` is the param's non-nil
      # type as returned by `own_attribute_establishment_type`, so it is non-nil
      # only when the body already wrote its own backing with the bare param — and
      # that write is exactly what makes the read and the param the same object.
      # A setter that stores something else (`@session = value.presence`) leaves
      # `own_type` nil and proves nothing here.
      #
      # Resolution goes through `own_type` and never through the reader's own
      # declared type, which is routinely `untyped`: a generated
      # `def session; @session; end` sidecar carries no type for the attribute, so
      # `type_of(rhs)` — what `param_guarded_nonnil_type` tries first — would
      # refuse every one of these.
      def own_attr_guarded_nonnil_type(rhs, own_attr, own_type)
        return nil unless own_type
        return nil unless rhs.is_a?(Parser::AST::Node) && (rhs.type == :send || rhs.type == :csend)
        return nil unless own_attr_read?(rhs.children[0], own_attr)

        ret = resolve_method_return(own_type, rhs.children[1]) or return nil
        subtract_nil(ret) == ret ? ret : nil
      end

      # The three spellings of reading the attribute a setter sets: the bare reader
      # (`session`), the explicit receiver (`self.session`), and the backing ivar
      # (`@session`). An argument-taking send of the same name is a different
      # method, not the reader.
      def own_attr_read?(node, own_attr)
        return false unless node.is_a?(Parser::AST::Node)

        case node.type
        when :send
          receiver, name, *args = node.children
          name == own_attr && args.empty? &&
            (receiver.nil? || (receiver.is_a?(Parser::AST::Node) && receiver.type == :self))
        when :ivar
          node.children[0] == :"@#{own_attr}"
        else
          false
        end
      end

      # The return type of `method` resolved on `type` (walking union/
      # intersection members), or nil.
      #
      # Every member that declares the method contributes a candidate, and the MOST
      # SPECIFIC one wins (felixefelip/steep#102). Returning the first match instead threw
      # away exactly what a refinement marker exists to say: for
      # `(User & User::Validated)`, `::User` is reached first and answers
      # `caderneta: () -> Caderneta?`, so the marker's proven
      # `caderneta: () -> (Caderneta & Caderneta::Validated)` was never consulted and the
      # establishment was refused as nilable.
      def resolve_method_return(type, method)
        candidates = instance_type_names(type).filter_map do |type_name|
          definition = @definition_builder.build_instance(type_name) rescue next
          method_def = definition.methods[method] or next
          types = method_def.method_types.map { |mt| @factory.type(mt.type.return_type) }
          next if types.empty?

          types.size == 1 ? types.first : AST::Types::Union.build(types: types)
        end
        return nil if candidates.empty?

        most_specific(candidates)
      end

      # The narrowest of a set of candidate types: one that is a strict subtype of every
      # other survivor. Falls back to the first when they are unrelated — an intersection
      # of unrelated types is not something this can usefully collapse, and the first is
      # what the previous behaviour returned.
      def most_specific(candidates)
        candidates.reduce do |best, candidate|
          strict_subtype?(candidate, best) ? candidate : best
        end
      end

      def instance_type_names(type)
        case type
        when AST::Types::Name::Instance
          [type.name]
        when AST::Types::Intersection, AST::Types::Union
          type.types.flat_map { |t| instance_type_names(t) }
        else
          []
        end
      end

      # The halt gate of a method: the gate of the first top-level guard-clause
      # that halts and returns. Independent of what the clause's condition tests
      # — item 3's write isn't in the clause, it just shares the exit gate.
      # Yields `[establishing_clause, gate]` for every top-level two-clause `if`
      # whose OTHER clause halts. Both polarities are tried, since nothing in the
      # shape says which side is which — `if c; establish; else; halt; end` and
      # its mirror read the same.
      #
      # The halting clause needs no `return`, unlike the one-armed guard: it IS
      # the end of its branch, so falling out of it leaves the method with the
      # gate set, and the caller's halt check is what stops there.
      #
      # `halting_gate` is deliberately loose — any self-send is a candidate — so
      # a clause that merely logs would offer a gate too. That is filtered later
      # rather than here: `Runner#resolve_gates!` drops a spec whose `gate_via`
      # resolves to no ivar once the may-write closure is known, which is the
      # same protection every other gate in this file relies on.
      def each_halting_alternative(body)
        each_statement(body) do |stmt|
          next unless stmt.is_a?(Parser::AST::Node) && stmt.type == :if

          _cond, true_clause, false_clause = stmt.children
          next unless true_clause && false_clause

          # Both pairings are offered, and the const writes decide which one is
          # real: `halting_gate` answers for any self-send, so the establishing
          # clause can look halting too (`Current.user = proven_user` calls
          # `proven_user`). Committing to a polarity here picked the wrong clause
          # whenever it did.
          if (gate = halting_gate(false_clause))
            yield true_clause, gate
          end
          if (gate = halting_gate(true_clause))
            yield false_clause, gate
          end
        end
      end

      # felixefelip/steep#117 gap 3c. The operands of a `||` chain written as a
      # top-level statement, in order, each as the `"Owner#method"` keys it
      # resolves to:
      #
      #   def require_authentication
      #     resume_session || authenticate_by_bearer_token || request_authentication
      #   end
      #
      # The Runner turns these into a fact: if the LAST operand always halts,
      # then an exit that did not halt means an earlier operand returned truthy,
      # so whatever they all establish on such an exit holds. The last operand
      # carrying the halt is not a detail — without it, every operand returning
      # falsy is an exit that halted nothing and established nothing.
      #
      # Only plain sends qualify. An operand that is itself an expression
      # (`a && b`, a literal, an assignment) names no method to look facts up on.
      def collect_disjunction_operands(def_node)
        body = def_node.children[2]
        return [] unless body

        chains = [] #: Array[Array[Set[String]]]
        each_statement(body) do |stmt|
          next unless stmt.is_a?(Parser::AST::Node) && stmt.type == :or

          operands = flatten_disjunction(stmt).map do |operand|
            next nil unless operand.is_a?(Parser::AST::Node) && operand.type == :send

            keys = Set.new #: Set[String]
            collect_call_keys(operand, keys)
            keys.empty? ? nil : keys
          end
          chains << operands if operands.size >= 2 && !operands.include?(nil)
        end
        chains
      end

      # `(or (or a b) c)` -> [a, b, c].
      def flatten_disjunction(node)
        return [node] unless node.is_a?(Parser::AST::Node) && node.type == :or

        left, right = node.children
        flatten_disjunction(left) + flatten_disjunction(right)
      end

      def method_halt_gate(body)
        each_statement(body) do |stmt, terminal|
          next unless stmt.is_a?(Parser::AST::Node) && stmt.type == :if

          _, true_clause, false_clause = stmt.children
          abort_clause = true_clause || false_clause
          next unless abort_clause && (true_clause.nil? ^ false_clause.nil?)
          next unless clause_returns?(abort_clause, terminal: terminal)

          gate = halting_gate(abort_clause) and return gate
        end
        nil
      end

      # `Current.user = <rhs>` => `["Current.user", rhs_node]`, else nil. The
      # receiver must be a constant (self/ivar writes are items 1/2's job).
      #
      # Keyed by the RESOLVED name, not the source spelling: `Registry.user =` in
      # `Outer::Host` keys `Outer::Registry.user`, which is what the read side
      # looks up. Written lexically it keyed `Registry.user` and never applied.
      def const_attr_write(node)
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :send

        method = node.children[1]
        return nil unless method.to_s.end_with?("=") && method != :==
        # An indexed write is not an attribute write. `ENV["KEY"] = value` would
        # key the path `ENV.[]`, which names no reader and asserts nothing about
        # any particular key — a fact that cannot be true or false. `[]=` also
        # takes two arguments, so `children[2]` below would be the KEY rather
        # than the written value. `walk_attr_writes` excludes it for the same
        # reason; only #117 gap 3b, reading inside a clause, ever reached one.
        return nil if method == :[]=

        receiver = node.children[0]
        return nil unless receiver.is_a?(Parser::AST::Node) && receiver.type == :const

        const_name = resolved_const_name(receiver) or return nil
        rhs = node.children[2] or return nil

        ["#{const_name}.#{method.to_s.chomp("=")}", rhs]
      end

      # The type of a written value, only when it is provably non-nil at that
      # point (so `Current.user` can be asserted present). A nilable or untyped
      # RHS yields nil — nothing is proven.
      def nonnil_value_type(rhs)
        type = type_of(rhs) or return nil
        return nil if type.is_a?(AST::Types::Any)
        return nil unless subtract_nil(type) == type # already nil-free

        type
      end

      # Matches `unless <presence test>; <halts>; return; end` (or the
      # `if !<presence test>` spelling) and returns `[facts, gate]`, where `gate`
      # is `{ gate_ivar: }` or `{ gate_via: }`. The aborting branch must both
      # halt (write an ivar directly, or call a self-method that does) and
      # `return`.
      #
      # `facts` is a LIST because one condition can prove several things — a
      # conjunction proves each conjunct (felixefelip/steep#105 gap 1c). Each is
      # tagged by what it names, so the collectors can take the ones they own.
      #
      # `terminal` says the guard is the last statement of its method, which is a
      # second way for the aborting branch to end it (gap 2) — see
      # `clause_returns?`.
      def negative_presence_guard(node, terminal: false)
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :if

        cond, true_clause, false_clause = node.children
        # `unless X` parses as `if X (nil-then) (else)` and `if X` as
        # `(if X (then) nil)`, so the aborting body is whichever clause exists;
        # require exactly one. WHICH one decides the polarity below.
        abort_clause = true_clause || false_clause
        return nil unless abort_clause && (true_clause.nil? ^ false_clause.nil?)
        return nil unless clause_returns?(abort_clause, terminal: terminal)

        facts = guard_facts(node, cond, aborts_on_truthy: !true_clause.nil?)
        return nil if facts.empty?

        gate = halting_gate(abort_clause) or return nil
        [facts, gate]
      end

      # What a guard proves on the exit that did NOT halt.
      #
      # Primary source is the checker itself: `typing.branch_envs` holds the envs
      # `LogicTypeInterpreter` computed for this very `if`, so the surviving
      # branch's narrowing IS the answer — no second implementation of truthiness,
      # and `present?`/`blank?`/`&&`/`nil?` all come for free because the
      # interpreter already partitions each union component by its declared return
      # type.
      #
      # The syntactic reading is UNIONED in rather than used only as a fallback,
      # for one structural reason: `x&.foo` narrows `x` in the env only when `x` is
      # a local variable. For a constant path (`Current.user&.active?`) the `:csend`
      # synthesis joins the env back to its pre-call state (`type_construction.rb`,
      # `when :csend`) precisely because the call may not have happened — and that
      # join drops the receiver's pure-call registration before the interpreter can
      # refine it. So the env genuinely does not hold that fact, and reading the
      # AST is covering a hole rather than duplicating a working answer. Both
      # readings are polarity-aware, so the union is additive, never contradictory.
      def guard_facts(if_node, cond, aborts_on_truthy:)
        # Abort in the THEN clause => the surviving exit is the falsy one.
        surviving = aborts_on_truthy ? :falsy : :truthy
        env_facts = env_guard_facts(if_node, surviving)
        (env_facts + syntactic_guard_facts(cond, aborts_on_truthy: aborts_on_truthy)).uniq
      end

      # The slots the surviving branch narrowed to non-nil, read off the recorded
      # envs. `entry` is the env after the condition was synthesized, so a pure
      # call in the condition is registered in both and the diff is exactly what
      # the branch proved. `[]` covers both "nothing was recorded" and "the branch
      # proved nothing": the caller unions the syntactic reading in either case,
      # so it has no use for the distinction.
      def env_guard_facts(if_node, surviving)
        record = @branch_envs[if_node] or return []

        entry_env = record[:entry]
        surviving_env = record[surviving]

        facts = [] #: Array[untyped]
        surviving_env.pure_method_calls.each_key do |send_node|
          before = entry_env[send_node] or next
          after = surviving_env[send_node] or next
          next unless nilable_type?(before) && !nilable_type?(after)

          facts.concat(slot_facts(send_node))
        end
        facts
      end

      def nilable_type?(type)
        case type
        when AST::Types::Nil
          true
        when AST::Types::Union
          type.types.any? {|t| t.is_a?(AST::Types::Nil) }
        else
          false
        end
      end

      # The AST reading. Polarity is explicit here because
      # it is the one thing this cannot ask anyone about:
      #
      #   abort in ELSE (`unless X`)  => survives when X is TRUTHY  => facts of X
      #   abort in THEN (`if !X`)     => survives when !X is falsy  => facts of X
      #   abort in THEN (`if X`)      => survives when X is FALSY   => nothing
      #
      # The third line is why the `!` unwrap is conditional: unwrapping
      # unconditionally proved the condition TRUE on the exit where it is false.
      # The unwrap also belongs to the WHOLE condition and must not reach its
      # parts — a negated conjunct (`A && !B`) proves `B` falsy, the opposite of
      # present — which is why `truthy_facts` never unwraps.
      def syntactic_guard_facts(cond, aborts_on_truthy:)
        if aborts_on_truthy
          if inner = negation_operand(cond)
            truthy_facts(inner)
          else
            []
          end
        else
          truthy_facts(cond)
        end
      end

      # `!X` => X, unwrapping parentheses. nil when `node` is not a negation.
      def negation_operand(node)
        return nil unless node.is_a?(Parser::AST::Node)
        return negation_operand(node.children.last) if node.type == :begin
        return nil unless node.type == :send && node.children[1] == :! && node.children[0]

        node.children[0]
      end

      # The facts implied by `node` being truthy, as a list of tagged facts:
      #
      #   `current_user`                => [{ self_method: :current_user }]
      #   `Current.user`                => [{ const_path: "Current.user" }]
      #   `Current.user&.active?`       => [{ const_path: "Current.user" }]
      #   `Current.account && ...`      => the facts of BOTH conjuncts
      #
      # The first two are the value being tested directly. The third is
      # felixefelip/steep#105 gap 1b: `x&.foo` evaluates to nil whenever `x` is
      # nil, so a truthy `x&.foo` proves `x` non-nil — exactly, with no knowledge
      # of what `foo` returns or whether it is nilable itself. The fact is about
      # the RECEIVER; the send through it is only the reason we are looking, which
      # is why its arguments are irrelevant.
      #
      # The fourth is gap 1c: `A && B` is truthy only if both are, so it proves
      # everything either conjunct does. A conjunct that decodes to nothing is
      # SKIPPED — it says nothing, which is no reason to discard what its
      # neighbour says. `||` is deliberately absent: a truthy disjunction says only
      # that at least one operand was, with no way to tell which.
      #
      # Anything else (a literal, a send whose receiver names no slot) yields no
      # fact.
      def truthy_facts(node)
        return [] unless node.is_a?(Parser::AST::Node)

        # Parentheses, and more generally a sequence: its value — and so its truth
        # — is the LAST expression's. `!(A && B)` puts one of these in the way.
        return truthy_facts(node.children.last) if node.type == :begin

        return node.children.flat_map { |child| truthy_facts(child) } if node.type == :and

        # A safe-navigated call: the proof is about what it was called ON.
        return slot_facts(node.children[0]) if node.type == :csend

        return [] unless node.type == :send
        # A DIRECT test names the slot itself, so it must BE one — a no-argument
        # read, not an arbitrary call that happens to return something truthy.
        return [] unless node.children[2..].to_a.empty?

        slot_facts(node)
      end

      # The fact naming `node` as a slot a caller could look up, or `[]`.
      #
      # A self receiver names a method of the enclosing class; a constant receiver
      # names a slot any caller can address, RESOLVED (#106) so it keys by identity
      # like every other const fact. A local, an ivar or a literal names nothing.
      #
      # A `csend` recurses into its own receiver: `a&.b&.c` is truthy only if every
      # link was non-nil, so the innermost nameable slot is proven. Only that one is
      # keyed — the intermediate hops are not slots a caller could look up.
      def slot_facts(node)
        return [] unless node.is_a?(Parser::AST::Node)
        return slot_facts(node.children[0]) if node.type == :csend
        return [] unless node.type == :send
        return [] unless node.children[2..].to_a.empty? # no args

        receiver = node.children[0]
        if receiver.nil? || receiver.type == :self
          [{ self_method: node.children[1] }]
        elsif receiver.type == :const
          base = resolved_const_name(receiver) or return []
          [{ const_path: "#{base}.#{node.children[1]}" }]
        else
          []
        end
      end

      # Whether taking `clause` ends the method — the property a guard needs, so
      # that the code AFTER it runs only on the other branch.
      #
      # An explicit `return` says so anywhere. felixefelip/steep#105 gap 2 adds the
      # other way: when the guard is the method's FINAL statement there is nothing
      # left to run, so falling off the end is exactly a return.
      #
      # `terminal` is doing all the work in that second case and has to stay exact.
      # A halting clause that is NOT last does not end the method — execution
      # continues past the `if` — so treating one as a guard would prove a fact on
      # a path that keeps going. This is the only place in the guard grammar where
      # being too permissive yields a WRONG proof rather than a missing one.
      def clause_returns?(clause, terminal: false)
        return true if terminal

        walk_nodes(clause) { |n| return true if n.type == :return }
        false
      end

      # How the abort clause halts: a direct ivar write (`{ gate_ivar: }`) or,
      # failing that, the self-methods it calls (`{ gate_via: }`, a list the Runner
      # resolves to the first one that actually writes an ivar). nil if neither.
      #
      # felixefelip/steep#105 gap 3: this used to commit to the FIRST self-send,
      # and no position is reliably the halt. `respond_to { redirect_to }` puts it
      # last (the first is the block-taking method, which writes nothing);
      # `redirect_to root_path` puts it first (the second is an argument). Guessing
      # wrong is not unsound — the flow's halt check tests a different ivar, so the
      # fact simply never applies — but it silently dropped the whole proof.
      #
      # Offering candidates in source order lets the Runner decide with the
      # information it has and the inferrer does not: which of them writes what.
      def halting_gate(clause)
        walk_nodes(clause) do |n|
          return { gate_ivar: n.children[0] } if n.type == :ivasgn
        end

        candidates = [] #: Array[Symbol]
        walk_nodes(clause) do |n|
          next unless n.type == :send
          receiver = n.children[0]
          candidates << n.children[1] if receiver.nil? || receiver.type == :self
        end
        return nil if candidates.empty?

        { gate_via: candidates.uniq }
      end

      # The declared return type of `self.<method>`, with `nil` subtracted —
      # the type it has on the proven-present exit. nil when the method has no
      # such declaration or isn't actually nilable.
      def nonnil_return_of_self_method(method, class_name, singleton:)
        type_name = RBS::TypeName.parse("::#{class_name}").absolute! rescue (return nil)
        definition =
          if singleton
            @definition_builder.build_singleton(type_name) rescue nil
          else
            @definition_builder.build_instance(type_name) rescue nil
          end
        return nil unless definition

        method_def = definition.methods[method] or return nil
        return_types = method_def.method_types.map { |mt| @factory.type(mt.type.return_type) }
        return nil if return_types.empty?

        ret = return_types.size == 1 ? return_types.first : AST::Types::Union.build(types: return_types)
        nonnil = subtract_nil(ret)
        nonnil unless nonnil == ret
      end

      def subtract_nil(type)
        return type unless type.is_a?(AST::Types::Union)

        remaining = type.types.reject { |t| t.is_a?(AST::Types::Nil) }
        return type if remaining.size == type.types.size
        return AST::Builtin.nil_type if remaining.empty?

        remaining.size == 1 ? remaining.first : AST::Types::Union.build(types: remaining)
      end

      # Yields each top-level statement of a (possibly `:begin`) body, along with
      # whether it is the LAST one — the position at which falling off the end is
      # indistinguishable from returning. Callers that don't care take one param
      # and the flag is dropped.
      def each_statement(body)
        if body.type == :begin
          statements = body.children.select { |c| c.is_a?(Parser::AST::Node) }
          statements.each_with_index { |c, i| yield c, i == statements.size - 1 }
        else
          yield body, true
        end
      end

      # Every `:send`/`:csend` descendant, including those inside block bodies —
      # the halt of a controller guard sits two blocks deep
      # (`respond_to { |f| f.html { redirect_to … } }`), and the block runs in
      # the same `self`, so its sends are ours.
      def walk_sends(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        yield node if node.type == :send || node.type == :csend
        node.children.each do |child|
          walk_sends(child, &block) if child.is_a?(Parser::AST::Node)
        end
      end

      # Every descendant node (including the node itself).
      def walk_nodes(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        yield node
        node.children.each do |child|
          walk_nodes(child, &block) if child.is_a?(Parser::AST::Node)
        end
      end

      # Recursively walks `node` yielding every `:ivasgn` descendant.
      def walk_ivasgns(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        yield node if node.type == :ivasgn
        node.children.each do |child|
          walk_ivasgns(child, &block) if child.is_a?(Parser::AST::Node)
        end
      end

      def declared_ivar_types(class_name, singleton:)
        return {} if class_name.empty?
        type_name = RBS::TypeName.parse("::#{class_name}").absolute!
        definition =
          if singleton
            @definition_builder.build_singleton(type_name) rescue nil
          else
            @definition_builder.build_instance(type_name) rescue nil
          end
        return {} unless definition
        definition.instance_variables.transform_values do |ivar|
          @factory.type(ivar.type)
        end
      end

    end

    # Minimal value object for an inferred entry. Distinct from
    # `Postconditions::Entry` (which represents loaded YAML entries) so
    # callers can serialize the inference output without round-tripping
    # through the loader.
    class InferredEntry
      attr_reader :class_name, :method_name, :singleton
      attr_reader :ivars, :self_type_string
      attr_reader :when_true_ivars, :when_true_self_type_string
      # Array[Symbol] of attribute names the method establishes non-nil
      # on its returned value (felixefelip/steep#56).
      attr_reader :returns_establishes
      # Set[Symbol] of ivars the method may write, directly or transitively
      # (felixefelip/steep#68). `self_call_deps` are the call-graph edges the
      # Runner closes over to compute the transitive part; they are not
      # serialized.
      attr_reader :may_write_ivars, :self_call_deps, :unconditional_call_deps
      attr_reader :when_true_consts, :when_true_call_deps, :disjunction_chains
      # felixefelip/steep#68 item 2. `returns_ivar`: this method transparently
      # reads that ivar (halt-check getter). `conditional_returns`:
      # { method => { gate_ivar:, type: } } self-methods proven non-nil on the
      # unhalted exit, gated by the ivar's falsy state.
      attr_reader :returns_ivar, :conditional_returns
      # felixefelip/steep#68 item 3: { "Const.attr" => { gate_ivar:, type: } } —
      # constant attributes proven non-nil on the unhalted exit.
      attr_reader :conditional_const_returns
      # felixefelip/steep#68 item 5. `establishes_consts` (instance setters): other
      # attributes set non-nil when the setter's arg is non-nil. `delegates_to_instance`
      # (singleton setters): whether `self.x=` forwards to `instance.x=`.
      attr_reader :establishes_consts, :delegates_to_instance
      # felixefelip/steep#100: { "Const.attr" => type } — constant attributes this method
      # writes non-nil on EVERY exit, because nothing in it can halt first. The
      # unconditional sibling of `conditional_const_returns`.
      attr_reader :const_establishments
      # felixefelip/rbs_infer#144 stage 2. `when_true_block_truthy`: a truthy
      # return of this method means the block it was given answered truthy.
      # `block_forward_deps` are the call-graph edges the Runner closes over to
      # carry that along a delegation chain; they are not serialized.
      attr_reader :when_true_block_truthy, :block_forward_deps

      def initialize(class_name:, method_name:, singleton:, ivars: {}, self_type_string: nil, when_true_ivars: {}, when_true_self_type_string: nil, returns_establishes: [], may_write_ivars: Set[], self_call_deps: Set[], unconditional_call_deps: Set[], when_true_consts: {}, when_true_call_deps: Set[], disjunction_chains: [], when_true_block_truthy: false, block_forward_deps: Set[], returns_ivar: nil, conditional_returns: {}, conditional_const_returns: {}, establishes_consts: {}, const_establishments: {}, delegates_to_instance: false)
        @class_name = class_name
        @method_name = method_name
        @singleton = singleton
        @ivars = ivars
        @self_type_string = self_type_string
        @when_true_ivars = when_true_ivars
        @when_true_self_type_string = when_true_self_type_string
        @returns_establishes = returns_establishes
        @may_write_ivars = may_write_ivars
        @self_call_deps = self_call_deps
        @unconditional_call_deps = unconditional_call_deps
        @when_true_consts = when_true_consts
        @when_true_call_deps = when_true_call_deps
        @disjunction_chains = disjunction_chains
        @when_true_block_truthy = when_true_block_truthy
        @block_forward_deps = block_forward_deps
        @returns_ivar = returns_ivar
        @conditional_returns = conditional_returns
        @conditional_const_returns = conditional_const_returns
        @establishes_consts = establishes_consts
        @const_establishments = const_establishments
        @delegates_to_instance = delegates_to_instance
      end

      # A copy with `may_write_ivars` replaced — the Runner's fixpoint result.
      def with_may_write(ivars)
        InferredEntry.new(
          class_name: class_name, method_name: method_name, singleton: singleton,
          ivars: self.ivars, self_type_string: self_type_string,
          when_true_ivars: when_true_ivars, when_true_self_type_string: when_true_self_type_string,
          returns_establishes: returns_establishes,
          may_write_ivars: ivars, self_call_deps: self_call_deps,
          unconditional_call_deps: unconditional_call_deps,
          when_true_consts: when_true_consts, when_true_call_deps: when_true_call_deps,
          disjunction_chains: disjunction_chains,
          when_true_block_truthy: when_true_block_truthy, block_forward_deps: block_forward_deps,
          returns_ivar: returns_ivar, conditional_returns: conditional_returns,
          conditional_const_returns: conditional_const_returns,
          establishes_consts: establishes_consts, const_establishments: const_establishments,
          delegates_to_instance: delegates_to_instance
        )
      end

      # A copy with `establishes_consts` replaced — the Runner drops them when no
      # delegating singleton setter confirms the write path (piece 1).
      def with_establishes_consts(consts)
        InferredEntry.new(
          class_name: class_name, method_name: method_name, singleton: singleton,
          ivars: ivars, self_type_string: self_type_string,
          when_true_ivars: when_true_ivars, when_true_self_type_string: when_true_self_type_string,
          returns_establishes: returns_establishes,
          may_write_ivars: may_write_ivars, self_call_deps: self_call_deps,
          unconditional_call_deps: unconditional_call_deps,
          when_true_consts: when_true_consts, when_true_call_deps: when_true_call_deps,
          disjunction_chains: disjunction_chains,
          when_true_block_truthy: when_true_block_truthy, block_forward_deps: block_forward_deps,
          returns_ivar: returns_ivar, conditional_returns: conditional_returns,
          conditional_const_returns: conditional_const_returns,
          establishes_consts: consts, const_establishments: const_establishments,
          delegates_to_instance: delegates_to_instance
        )
      end

      # Whether the entry says anything a consumer can use. Entries that exist
      # only as call-graph nodes (no refinement, no effect) are dropped after
      # the fixpoint. `delegates_to_instance` is metadata the Runner consumes to
      # gate an instance setter's establishments, not a serialized fact — so it
      # does NOT keep an entry alive, but a surviving `establishes_consts` does.
      def empty?
        ivars.empty? && when_true_ivars.empty? && when_true_consts.empty? &&
          returns_establishes.empty? &&
          may_write_ivars.empty? && returns_ivar.nil? && conditional_returns.empty? &&
          conditional_const_returns.empty? && establishes_consts.empty? &&
          const_establishments.empty? && !when_true_block_truthy
      end

      # The Runner's fixpoint proving the fact one link further along the chain.
      # `block_forward_deps` is the edge; this is what travels it.
      def prove_block_truthy!
        @when_true_block_truthy = true
      end

      def ==(other)
        other.is_a?(InferredEntry) &&
          other.class_name == class_name &&
          other.method_name == method_name &&
          other.singleton == singleton &&
          other.ivars == ivars &&
          other.self_type_string == self_type_string &&
          other.when_true_ivars == when_true_ivars &&
          other.when_true_self_type_string == when_true_self_type_string &&
          other.returns_establishes == returns_establishes &&
          other.may_write_ivars == may_write_ivars
      end

      alias eql? ==

      def hash
        class_name.hash ^ method_name.hash ^ singleton.hash ^ ivars.hash ^ self_type_string.hash ^
          when_true_ivars.hash ^ when_true_self_type_string.hash ^ returns_establishes.hash ^
          may_write_ivars.hash
      end
    end
  end
end
