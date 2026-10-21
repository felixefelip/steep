module Steep
  module Specializations
    # The source a method writes with `class_eval`/`module_eval` on a STRING,
    # read at one call site of that method.
    #
    #     def has_rich_text(name)
    #       class_eval "def #{name}; rich_text_#{name}; end"
    #     end
    #
    #     has_rich_text :content
    #
    # A checker cannot see inside that string, and neither can any other static
    # reader: the text does not exist until an argument supplies it. But it is
    # not dynamic in the `eval`/`method_missing` sense — the call site says what
    # `name` is, and a specialized body types `name` as `:content`, so the
    # interpolation folds to a literal and the string IS its own type.
    #
    # Two questions have to be answered per chunk, and this asks the checker
    # both: WHAT the string says, which is its literal type, and WHETHER it runs,
    # which is narrowing. Nothing here evaluates an expression or decides a
    # condition on its own; it walks the body's control flow to find out which
    # answer applies where, and every shape it does not model is UNKNOWN rather
    # than assumed.
    module Evals
      # Written, never read back: nothing in Steep needs the text, since a
      # string it can fold is a string it has already typed. It is written for
      # the generator on the other side, which turns it into the Ruby the class
      # actually has (felixefelip/rbs_infer#343).
      DEFAULT_OUTPUT_PATH = Pathname("sig/generated/.steep_string_evals.yml").freeze
      # 2 lets a chunk name the class it lands on; 1 could only write the source
      # and leave the WHERE to the consumer, which can answer it for an eval on
      # the caller's own self and for nothing else (felixefelip/steep#175). 3
      # says when that class is a module (felixefelip/steep#208).
      SCHEMA_VERSION = 3

      # Bodies the call does not run: a lambda it returns, a block it stores, a
      # method it defines. `-> { class_eval "def #{name}; end" }` writes nothing
      # until something calls it, and nothing here knows whether anything does.
      DEFERRED = %i[def defs sclass block numblock].freeze

      # A dead branch still gets a type — Steep synthesizes it to report errors
      # in it — so "folded to a literal" does not mean "runs". These are the
      # diagnostics that say it does not.
      UNREACHABLE = [
        Diagnostic::Ruby::UnreachableBranch,
        Diagnostic::Ruby::UnreachableValueBranch
      ].freeze

      # The `self_target` of a frame entered on a receiver naming no class.
      UNNAMED_SELF = :unnamed

      SUPERS = %i[super zsuper].freeze
      CALLS = [:send, *SUPERS].freeze

      class << self
        # One thing a body does that writes code, in source order.
        #
        # `:eval` is a string eval, and `:const_set` and `:include` write a
        # module and an ancestor where an eval writes a method. `:frame` is a
        # call to a method that writes any of them, on its own receiver or on
        # an object it is handed; its body is read under the arguments this call
        # passes.
        #
        # `certain` is whether the call site's arguments decide it runs at all.
        Effect = Struct.new(:kind, :node, :callee, :certain, keyword_init: true)

        # A chunk of source, and the class it lands on — nil for the class whose
        # body holds the macro call, which is the only one the consumer can work
        # out on its own. `kind` is `"module"` for a target declared as one.
        Chunk = Struct.new(:source, :target, :kind, keyword_init: true)

        Walk = Struct.new(:writers, :typing, :overrides, :method_name, keyword_init: true)

        # Whether the method writes code, directly or through a method it calls.
        # The gate that keeps a project without the idiom from paying for a
        # single extra check, so it reads the AST and nothing else.
        def writes_code?(def_node, writers = Set[])
          walk = Walk.new(writers: writers, typing: nil, method_name: method_name(def_node))
          each_effect(body_of(def_node), nil, true, walk) { return true }
          false
        end

        # The chunk one write makes, or nil for a hole — a branch the call site
        # does not decide, a value it does not fix, or a write on a `self` that
        # names no class. `self_target` is the class a write on `self` lands
        # on: nil in the frame of the macro call itself, the receiver's class in
        # a frame entered through one.
        def chunk_of(typing, effect, env, self_target = nil)
          return nil unless effect.certain
          return nil if self_target == UNNAMED_SELF && on_self?(effect.node)

          source =
            case effect.kind
            when :eval then literal_string(typing, effect.node)
            when :const_set then constant_source(typing, effect.node)
            when :include then include_source(typing, effect.node)
            end
          return nil unless source

          target = on_self?(effect.node) ? self_target : eval_target(typing, effect.node)
          Chunk.new(source: source, target: target, kind: target && module_kind(target, env))
        end

        # Every effect of this body, written and called, in source order and
        # each carrying the flow's verdict. A macro that evals once and then
        # calls a writer writes both, and the class gets them in the order it is
        # written.
        def effects(typing, def_node, writers, overrides:)
          flow = Flow.new(typing)
          result = [] #: Array[Effect]
          walk = Walk.new(writers: writers, typing: typing, overrides: overrides, method_name: method_name(def_node))

          each_effect(body_of(def_node), flow, true, walk) do |effect|
            result << effect
          end

          result
        end

        # The text one eval writes, for a consumer holding an effect rather than
        # walking the body itself.
        def source_of(typing, node)
          literal_string(typing, node)
        end

        def body_of(def_node)
          def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        end

        def method_name(def_node)
          def_node.type == :defs ? def_node.children[1] : def_node.children[0]
        end

        def on_self?(node)
          return true if SUPERS.include?(node.type)

          receiver = node.children[0]
          receiver.nil? || receiver.type == :self
        end

        # The class a call's receiver NAMES exactly.
        #
        #   Target.class_eval "…"          # singleton(::Outer::Target)
        #   target = Target; target.…      # the local keeps it
        #   owner.module_eval "…"          # whatever the frame handed `owner`
        #   self.class_eval "…"            # `self` — a type variable, not a name
        #   Target.singleton_class.…       # singleton_class(::Target) — a class,
        #                                  # on the side an entry has no field for
        #
        # nil for the last two, which decline: `self` names no class, and since
        # S2 of #171 a singleton class names one — but on the SINGLETON side,
        # and an entry records a class rather than a side, so a def written
        # there would be placed as an instance method
        # (felixefelip/steep#175).
        def eval_target(typing, node)
          receiver = node.children[0]
          return nil if receiver.nil? || receiver.type == :self
          return nil unless typing.has_type?(receiver)

          type = typing.type_of(node: receiver)
          return nil unless type.is_a?(AST::Types::Name::Singleton)

          type.name.to_s
        end

        # A string eval whose text only defines methods: running it changes
        # nothing any object holds.
        def defines_only?(typing, node)
          return false unless written_kind(node, Walk.new(writers: Set[], typing: typing)) == :eval

          source = source_of(typing, node) or return false
          parsed = Prism.parse(source)
          parsed.errors.empty? && parsed.value.statements.body.all?(Prism::DefNode)
        end

        private

        def resolved_send_key(node, walk)
          typing = walk.typing
          walk.overrides.body_key(
            typing.call_of(node: node), node: node, exact_self: typing.exact_self_of_call(node: node), self_type: typing.self_type_of_call(node: node)
          )
        rescue Typing::UnknownNodeError
          nil
        end

        # A `super` runs the one body its declaration names, whatever class
        # `self` is.
        def super_key(node, typing)
          call = typing.call_of(node: node)
          Specializations.method_key(call.method_decls) if call.is_a?(TypeInference::MethodCall::Typed)
        rescue Typing::UnknownNodeError
          nil
        end

        # Any writer of the method's name: the class a constant spells may
        # inherit it from one named otherwise, and the typed walk decides.
        def named_writers(node, walk)
          name = SUPERS.include?(node.type) ? walk.method_name : node.children[1]
          walk.writers.select { |key| key.end_with?(".#{name}", "##{name}") }
        end

        # `certain` is whether the call site's arguments decide that this point
        # runs. It starts true — a statement in the body runs when the method is
        # called — and only a branch nobody decided takes it away.
        #
        # `flow` is nil when the caller only asks WHETHER code is written, which
        # needs no decisions and no typing.
        # Both kinds of effect come out of ONE walk, so a call to a writer is
        # classified by the same control flow an eval is: a branch the call site
        # kills is not reached, and one it does not decide takes `certain` away
        # from whatever is inside it. `Writer.generate(self, name) if enabled`
        # writes nothing when the call site fixes `enabled` to false, and that is
        # not a fact the AST alone can produce.
        #
        # A write is yielded after what its receiver and arguments do, which
        # Ruby runs first: `generated_methods.class_eval "…"` builds the module
        # before it writes into it.
        def each_effect(node, flow, certain, walk, &block)
          return unless node.is_a?(Parser::AST::Node)
          return if DEFERRED.include?(node.type)

          if (effect = write_at(node, certain, walk))
            node.children.each { |child| each_effect(child, flow, certain, walk, &block) }
            yield effect
            return
          end

          children = flow ? flow.branches(node) : nil
          if children
            children.each do |child, state|
              next if state == :dead

              each_effect(child, flow, certain && state == :certain, walk, &block)
            end
          else
            node.children.each { |child| each_effect(child, flow, certain, walk, &block) }
          end
        end

        def write_at(node, certain, walk)
          node = walk.typing.explicit_super_of(node: node) || node if node.type == :zsuper && walk.typing
          if (kind = written_kind(node, walk))
            Effect.new(kind: kind, node: node, certain: certain)
          elsif (callee = called_writer(node, walk))
            Effect.new(kind: :frame, node: node, callee: callee, certain: certain)
          end
        end

        # Which writer a call runs, as the checker resolved it. A constant is
        # written relative to where the call sits — `Module#delegate` calls
        # `Delegation.generate` from inside `module ActiveSupport` — and only the
        # typing knows what it names, so the callee is keyed as every call site
        # is: by its declaration. Without a typing, any writer of that name.
        def called_writer(node, walk)
          return nil if walk.writers.empty? || !CALLS.include?(node.type)
          return named_writers(node, walk).first unless walk.typing

          key = node.type == :send ? resolved_send_key(node, walk) : super_key(node, walk.typing)
          key if key && walk.writers.include?(key)
        end

        # What a `class_eval` of a string, a `const_set` or an `include` writes,
        # on `self` or on a receiver whose type names a class.
        #
        # Receiverless or written `self.class_eval`, it is the SAME call: the
        # implicit receiver of the first IS self, and a macro that spells it out
        # writes code in exactly the place a macro that does not.
        #
        # Any other receiver is read by its type, under the arguments the body
        # is checked with: a constant names its class, and a parameter names
        # whatever the frame that called this one handed it. One whose type
        # names no class has no WHERE to record, and declines.
        #
        # A block is `ClassEvalExpander`'s shape and is plain Ruby a reader
        # already sees.
        def written_kind(node, walk)
          return nil unless node.type == :send

          kind = WRITES[node.children[1]] or return nil
          return nil unless accepted_receiver?(node, walk.typing)

          arguments = node.children.drop(2)
          case kind
          when :eval then kind if accepted_argument?(arguments.first)
          when :const_set then kind if arguments.size == 2
          when :include then kind if !arguments.empty? && arguments.none? { |argument| FORWARDED_ARGUMENTS.include?(argument.type) }
          end
        end

        WRITES = { class_eval: :eval, module_eval: :eval, const_set: :const_set, include: :include }.freeze

        # Whether this is the STRING form. `class_eval` handed an argument at all
        # is: the block form takes none. So the argument's value is not what
        # decides it — a `join` that does not fold has written code exactly as a
        # heredoc has, only code this call site does not fix, and that is a hole
        # (`literal_string` answers nil), not an absence. `ActiveSupport::
        # Delegation` hands `module_eval` a `join`.
        #
        # `&block` and `*args` are the exceptions: a forwarder written with them
        # does not say which form runs, and the block one writes no string.
        def accepted_argument?(argument)
          return false if argument.nil?

          !FORWARDED_ARGUMENTS.include?(argument.type)
        end

        FORWARDED_ARGUMENTS = %i[block_pass splat].freeze

        # `typing` is nil for the cheap gate that only asks WHETHER a method
        # writes code, and that pass takes any receiver on the syntax alone —
        # deciding it needs a type, and the point of the gate is to avoid paying
        # for one.
        def accepted_receiver?(node, typing)
          return true if typing.nil? || on_self?(node)

          !eval_target(typing, node).nil?
        end

        # A value not built here is an existing module given a second name,
        # which no declaration says.
        def constant_source(typing, node)
          name_node, value = node.children.drop(2)
          name = literal_symbol(typing, name_node) or return nil
          return nil unless name.match?(/\A[A-Z]\w*\z/)
          return nil unless value.type == :send && value.children[1] == :new && typing.has_type?(value.children[0] || value)

          constructor = typing.type_of(node: value.children[0] || value)
          return nil unless constructor.is_a?(AST::Types::Name::Singleton)

          superclass = value.children[2..] || []
          case constructor.name
          when RBS::BuiltinNames::Module.name then "module #{name}\nend" if superclass.empty?
          when RBS::BuiltinNames::Class.name
            parent = superclass.empty? ? "" : (named_class(typing, superclass) or return nil)
            "class #{name}#{parent}\nend"
          end
        end

        def named_class(typing, arguments)
          return nil unless arguments.size == 1 && typing.has_type?(arguments.first)

          type = typing.type_of(node: arguments.first)
          " < #{type.name}" if type.is_a?(AST::Types::Name::Singleton)
        end

        def include_source(typing, node)
          names = node.children.drop(2).map do |argument|
            return nil unless typing.has_type?(argument)

            type = typing.type_of(node: argument)
            return nil unless type.is_a?(AST::Types::Name::Singleton)

            type.name.to_s
          end

          "include #{names.join(", ")}"
        end

        def literal_symbol(typing, node)
          return node.children[0].to_s if node.type == :sym
          return nil unless typing.has_type?(node)

          type = typing.type_of(node: node)
          type.value.to_s if type.is_a?(AST::Types::Literal) && type.value.is_a?(Symbol)
        end

        def module_kind(target, env)
          "module" if env.class_decls[RBS::TypeName.parse(target)].is_a?(RBS::Environment::ModuleEntry)
        end

        def literal_string(typing, node)
          argument = node.children[2]
          return nil unless typing.has_type?(argument)

          type = typing.type_of(node: argument)
          return nil unless type.is_a?(AST::Types::Literal) && type.value.is_a?(String)

          type.value
        end
      end

      # Which parts of a body this call site runs, read off the check of it.
      #
      # A branch is `:dead` when the checker reported it unreachable, `:certain`
      # when it is the only branch of its conditional that is not, and
      # `:unknown` otherwise — which is the case that matters, because a
      # condition the arguments do not decide leaves BOTH branches folding and a
      # consumer would otherwise be handed two methods where the class has one.
      class Flow
        def initialize(typing)
          @typing = typing
          @dead = unreachable_ranges(typing)
        end

        # `[[child, state], …]` for a node whose children do not all run, or nil
        # for one whose children do. A shape not modelled here has no entry, so
        # it is walked as an ordinary sequence — which is why only the shapes
        # that can SKIP something are listed.
        def branches(node)
          case node.type
          when :if then conditional(node)
          when :or_asgn then [[node.children[0], :certain], [node.children[1], ARM_STATES.fetch(@typing.arm_of(node: node), :unknown)]]
          when :case then case_branches(node)
          when :case_match then deferred_children(node, 1)
          when :and, :or then [[node.children[0], :certain], [node.children[1], :unknown]]
          when :while, :until, :while_post, :until_post
            [[node.children[0], :certain], [node.children[1], :unknown]]
          when :for then [[node.children[1], :certain], [node.children[2], :unknown]]
          when :rescue, :ensure then deferred_children(node, 1)
          end
        end

        def dead?(node)
          return false unless node

          range = node.loc&.expression or return false
          @dead.any? { |other| other.begin_pos <= range.begin_pos && range.end_pos <= other.end_pos }
        end

        private

        ARM_STATES = { then: :certain, else: :dead }.freeze

        # `unless` and a ternary are `:if` nodes too, the parser having already
        # put the clauses in `then`/`else` order.
        def conditional(node)
          predicate, then_clause, else_clause = node.children
          taken = decide(predicate, then_clause, else_clause)

          [
            [predicate, :certain],
            [then_clause, state_for(:then, taken, then_clause)],
            [else_clause, state_for(:else, taken, else_clause)]
          ]
        end

        # `:then`, `:else`, or nil when the arguments leave the condition open.
        #
        # An unreachable clause is the checker's own answer and comes first. A
        # predicate whose type is a literal answers the case it cannot report: a
        # decided `if` with no `else` has no clause to call unreachable, so
        # nothing would be said about it at all.
        def decide(predicate, then_clause, else_clause)
          return :then if dead?(else_clause)
          return :else if dead?(then_clause)

          case type_of(predicate)
          when AST::Types::Literal then literal_truthy?(predicate) ? :then : :else
          when AST::Types::Nil then :else
          end
        end

        def literal_truthy?(predicate)
          value = type_of(predicate).value #: untyped
          value != false
        end

        def state_for(branch, taken, clause)
          return :dead if clause && dead?(clause)
          return :unknown unless taken

          taken == branch ? :certain : :dead
        end

        # A branch of a `case` runs only when every other one is unreachable.
        # With three `when`s and one of them reported dead, the remaining two are
        # both live and neither is decided.
        def case_branches(node)
          _subject, *whens, else_clause = node.children
          bodies = whens.map { |clause| clause.children.last } + [else_clause]
          live = bodies.count { |body| body && !dead?(body) }

          entries = [[node.children[0], :certain]] #: Array[[untyped, Symbol]]
          whens.each { |clause| clause.children[0...-1].each { |cond| entries << [cond, :certain] } }
          bodies.each do |body|
            next unless body

            entries << [body, dead?(body) ? :dead : (live == 1 ? :certain : :unknown)]
          end
          entries
        end

        # The first child runs; everything after it may not.
        def deferred_children(node, first)
          node.children.each_with_index.map do |child, index|
            [child, index < first ? :certain : :unknown]
          end
        end

        def type_of(node)
          return nil unless node && @typing.has_type?(node)

          @typing.type_of(node: node)
        end

        def unreachable_ranges(typing)
          reported = typing.errors.filter_map do |error|
            next unless UNREACHABLE.any? { |klass| error.is_a?(klass) }

            error.node&.loc&.expression
          end
          reported + typing.dead_clauses.each_key.filter_map { |clause| clause.loc&.expression }
        end
      end
    end
  end
end
