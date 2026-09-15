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
      EVAL_METHODS = %i[class_eval module_eval].freeze

      # Written, never read back: nothing in Steep needs the text, since a
      # string it can fold is a string it has already typed. It is written for
      # the generator on the other side, which turns it into the Ruby the class
      # actually has (felixefelip/rbs_infer#343).
      DEFAULT_OUTPUT_PATH = Pathname("sig/generated/.steep_string_evals.yml").freeze
      SCHEMA_VERSION = 1

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

      class << self
        # Whether the method writes code ON ITS OWN SELF, which is the gate that
        # keeps a project without the idiom from paying for a single extra
        # check. Sources for one of these are read from this body, at this
        # method's own call sites.
        def writes_code?(def_node)
          walk(body_of(def_node), nil, true, EVAL_ON_SELF) { return true }
          false
        end

        # The positions of the parameters a body writes code on instead —
        # `owner.module_eval "…"` in `generate(owner, name)` answers `[0]`.
        #
        # A method like that is NOT a writer in its own right: it writes on an
        # object it was handed, so its own call site is the wrong place to
        # attribute anything to. It becomes one only through a frame that passes
        # its own `self` there, which is what `Runner#delegating_writers` looks
        # for.
        def eval_parameters(def_node)
          names = parameter_names(def_node)
          found = Set[] #: Set[Integer]

          walk(body_of(def_node), nil, true, names) do |node, _certain|
            receiver = node.children[0]
            next unless receiver&.type == :lvar

            index = names.index(receiver.children[0]) and found << index
          end

          found
        end

        # The positional parameters of a def, in order, so an eval written on one
        # can be matched against the argument a caller passes there.
        def parameter_names(def_node)
          args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
          return [] unless args

          args.children.filter_map do |arg|
            arg.children[0] if arg.type == :arg || arg.type == :optarg
          end
        end

        # The strings this body evals, in source order, with nil for one whose
        # value this call site does not fix OR whose execution it does not
        # decide. A nil is reported rather than dropped: a consumer rendering
        # the list needs to know its macro was read in part, since a class given
        # a reader whose writer was skipped is worse than one given neither.
        def sources(typing, def_node)
          flow = Flow.new(typing)
          result = [] #: Array[String?]
          receivers = EVAL_ON_SELF + parameter_names(def_node)

          walk(body_of(def_node), flow, true, receivers) do |node, certain|
            result << (certain ? literal_string(typing, node) : nil)
          end

          result
        end

        def body_of(def_node)
          def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        end

        # The send in `body` that hands this method's own `self` to a method
        # which evals on the parameter it lands in, with that method's key:
        #
        #   Writer.generate(self, name)   # `Writer.generate` evals on parameter 0
        #
        # Read off the AST, so the target has to be named by a constant. That is
        # the shape a framework writes (`::ActiveSupport::Delegation.generate`),
        # and a receiver this cannot name is one whose method this cannot find.
        #
        # `self` written at the call site is the whole proof that the two frames
        # share an object — a syntactic check, not an alias analysis.
        def delegated_writer(body, parameter_writers)
          each_send(body) do |node|
            key = constant_send_key(node) or next
            indices = parameter_writers[key] or next
            next unless indices.any? { |index| node.children[2 + index]&.type == :self }

            return [key, node]
          end

          nil
        end

        private

        def each_send(node, &block)
          return unless node.is_a?(Parser::AST::Node)
          return if DEFERRED.include?(node.type)

          yield node if node.type == :send
          node.children.each { |child| each_send(child, &block) }
        end

        # `"Writer.generate"` for `Writer.generate(…)`, matching how a singleton
        # method keys itself, or nil for any receiver that is not a constant.
        def constant_send_key(node)
          receiver = node.children[0]
          return nil unless receiver&.type == :const

          name = constant_path(receiver) or return nil
          "#{name}.#{node.children[1]}"
        end

        def constant_path(node)
          parent, name = node.children
          return name.to_s if parent.nil? || parent.type == :cbase
          return nil unless parent.type == :const

          prefix = constant_path(parent) or return nil
          "#{prefix}::#{name}"
        end

        # `certain` is whether the call site's arguments decide that this point
        # runs. It starts true — a statement in the body runs when the method is
        # called — and only a branch nobody decided takes it away.
        #
        # `flow` is nil when the caller only asks WHETHER code is written, which
        # needs no decisions and no typing.
        def walk(node, flow, certain, receivers, &block)
          return unless node.is_a?(Parser::AST::Node)
          return if DEFERRED.include?(node.type)

          if eval_send?(node, receivers)
            yield node, certain
            return
          end

          children = flow ? flow.branches(node) : nil
          if children
            children.each do |child, state|
              next if state == :dead

              walk(child, flow, certain && state == :certain, receivers, &block)
            end
          else
            node.children.each { |child| walk(child, flow, certain, receivers, &block) }
          end
        end

        # What `walk` is asked to read a receiver as. `nil` stands for self —
        # receiverless or written `self.` — and a Symbol for a parameter of the
        # def, which only the delegating shape passes.
        EVAL_ON_SELF = [nil].freeze

        # A `class_eval` on this method's own self, with a string argument.
        #
        # Receiverless or written `self.class_eval`, it is the SAME call: the
        # implicit receiver of the first IS self, and a macro that spells it out
        # writes code in exactly the place a macro that does not. What the
        # consumer does with the answer is why the distinction matters at all —
        # it places the source in the class whose body holds the macro call, so
        # an eval that runs anywhere else would be placed somewhere it does not
        # belong.
        #
        # Every other receiver still declines. A constant names a class this
        # call site did not choose, and a variable — `owner.module_eval`, the
        # shape `ActiveSupport::Delegation` uses — names an object only the
        # frame that passed it can identify, which is felixefelip/steep#171 S5b.
        #
        # A block is `ClassEvalExpander`'s shape and is plain Ruby a reader
        # already sees.
        def eval_send?(node, receivers)
          return false unless node.type == :send
          return false unless accepted_receiver?(node.children[0], receivers)
          return false unless EVAL_METHODS.include?(node.children[1])

          argument = node.children[2]
          argument&.type == :str || argument&.type == :dstr
        end

        def accepted_receiver?(receiver, receivers)
          return receivers.include?(nil) if receiver.nil? || receiver.type == :self
          return false unless receiver.type == :lvar

          receivers.include?(receiver.children[0])
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
          when :case then case_branches(node)
          when :case_match then deferred_children(node, 1)
          when :and, :or then [[node.children[0], :certain], [node.children[1], :unknown]]
          when :while, :until, :while_post, :until_post
            [[node.children[0], :certain], [node.children[1], :unknown]]
          when :for then [[node.children[1], :certain], [node.children[2], :unknown]]
          when :rescue, :ensure then deferred_children(node, 1)
          end
        end

        private

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

        def dead?(node)
          return false unless node

          range = node.loc&.expression or return false
          @dead.any? { |other| other.begin_pos <= range.begin_pos && range.end_pos <= other.end_pos }
        end

        def unreachable_ranges(typing)
          typing.errors.filter_map do |error|
            next unless UNREACHABLE.any? { |klass| error.is_a?(klass) }

            error.node&.loc&.expression
          end
        end
      end
    end
  end
end
