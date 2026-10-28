module Steep
  # Per-argument-tuple return types (felixefelip/rbs_infer#345, stage S4).
  #
  # A declaration holds for every caller, so `(?flag_name: bool) -> String`
  # cannot say that the callers passing `true` get `"name_delete"`. That fact
  # lives in a sidecar, keyed by the method and by the argument types the call
  # site supplies:
  #
  #     ---
  #     version: 1
  #     methods:
  #       Example69::Foo#call:
  #         "(flag_name: true)": '"name_delete"'
  #         "(flag_name: false)": '"delete"'
  #
  # `Specializations::Runner` writes it, `TypeConstruction` reads it back at the
  # send and replaces the call's return type.
  module Specializations
    DEFAULT_SIDECAR_PATH = "sig/generated/.steep_specializations.yml".freeze
    SCHEMA_VERSION = 1

    class << self
      def load(base_dir, path: DEFAULT_SIDECAR_PATH)
        absolute = base_dir + path
        return Store.empty unless absolute.file?

        raw = YAML.safe_load(absolute.read, aliases: true)
        Store.from_hash(raw, source: absolute.to_s, base_dir: base_dir)
      rescue Psych::Exception, LoadError => exn
        Steep.logger.warn { "[specializations] failed to parse #{absolute}: #{exn.message}" }
        Store.empty
      end

      # nil where `self` may be any subclass: in a class method checked under
      # its declaration rather than for one call site.
      # The class a call is specialized for: the one its receiver is
      # (`Arguments.receiver_self`), where the body may observe which one that
      # is, or, for a class object, reaches an ivar of it, which is that
      # class's own (`ClassStates.reach`).
      #
      # An instance method is keyed only where it runs a body the receiver's
      # class inherits, which every class an instance of it may be runs alike:
      # its own body already has that class as `self`.
      def keyed_self(constr, call)
        receiver = Arguments.receiver_self(call, exact_self(constr)) or return nil
        reach = ObjectStates::ClassStates.reach(constr, call)
        return receiver if receiver.is_a?(AST::Types::Name::Singleton) && (reach.observes_self || !reach.ivars.empty?)

        receiver if reach.observes_self && inherited_alike?(constr, receiver, reach.methods)
      end

      # `methods` starts with the one called, as `ClassStates.reach` lists them.
      def inherited_alike?(constr, receiver, methods)
        owners = ->(type) { methods.map { |name| ObjectStates.resolved_body(constr, type, name)&.first } }
        expected = owners.(receiver)
        return false if expected.first.nil? || expected.first == receiver.name

        Overrides.new(factory: constr.checker.factory, registry: constr.constructor_bindings).subclasses(receiver.name).all? do |name|
          owners.(AST::Types::Name::Instance.new(name: name, args: [])) == expected
        end
      end

      # `call` with the return type recorded for the argument tuple this call site
      # supplies (felixefelip/rbs_infer#345, stage S4), or `call` unchanged.
      #
      # A call that takes a block is left alone: the recorded return was computed
      # for the arguments only, and a block can decide the return type on its own.
      # So is a `recv.name = value`, which evaluates to `value` whatever the
      # setter's body returns.
      def specialized_call(constr, node, call, block:)
        store = constr.specializations
        return call if store.empty? || block || call.method_name.match?(/\w=\z/)

        key = body_key(constr, call, node) or return call
        arguments = call_site_arguments(constr, node, call) or return call
        type = store.call_return_type(key, arguments, factory: constr.checker.factory) or return call

        call.with_return_type(ObjectStates.initialize_call?(call) ? constructed(type, call.return_type) : type)
      end

      # What a `Klass.new` recorded under the class whose `initialize` it runs
      # answers for the class it builds: a subclass inherits the body, and
      # its own methods may change what the body left
      # (`ObjectStates::Constructed.kept`). Arguments that met several
      # recorded calls answer the class alone.
      def constructed(type, built)
        return type unless built.is_a?(AST::Types::Name::Instance)

        state = ObjectStates.state_in(type) or return built
        AST::Types::ObjectState.new(back_type: built, ivars: state.ivars)
      end

      # The key of the body `call` runs, or nil where it may run another
      # (`Overrides`).
      def body_key(constr, call, node)
        Overrides.new(factory: constr.checker.factory, registry: constr.constructor_bindings)
          .body_key(call, node: node, exact_self: exact_self(constr), self_type: constr.self_type)
      end

      # The arguments `call`, being typed at `node`, is specialized under.
      def call_site_arguments(constr, node, call)
        Arguments.at_call(
          node, constr.typing, call,
          self_ivars: ObjectStates.call_ivars(constr, call), class_states: ObjectStates::ClassStates.of_call(constr, call),
          keyed_self: keyed_self(constr, call), exact_self: exact_self(constr)
        )
      end

      def exact_self(constr)
        type = constr.self_type
        return nil unless type.is_a?(AST::Types::Name::Singleton) || type.is_a?(AST::Types::Name::Instance)

        method_context = constr.context.method_context
        return type.is_a?(AST::Types::Name::Singleton) ? type : nil unless method_context
        def_node = method_context.node or return nil
        type if constr.specialization_arguments(def_node)&.self_type == type
      end

      # `type` written the way a signature can say it.
      #
      # An entry is recorded as `type.to_s` and read back through
      # `RBS::Parser.parse_type`, so a type RBS cannot spell does not survive
      # the sidecar — and does not fail loudly either: `method(::Foo#bar)`
      # parses as the ALIAS `method`, and `Set{"a"}` as a bare `Set`. The
      # boundary is here, where a type becomes the text of a record.
      def rbs_writable(type)
        return rbs_writable(type.back_type) if type.is_a?(AST::Types::NotInRBS)

        type.map_type { |child| rbs_writable(child) }
      end

      # `rbs_writable`, but an object whose ivars are known kept as one: the
      # sidecar spells it (`sidecar_value`).
      def sidecar_writable(type)
        type.is_a?(AST::Types::ObjectState) ? type.map_type { |child| sidecar_writable(child) } : rbs_writable(type)
      end

      # How the sidecar writes a return: as RBS, or, for an object whose ivars
      # are known, which RBS cannot spell, as its class and the value of each.
      def sidecar_value(type)
        return type.to_s unless type.is_a?(AST::Types::ObjectState)

        { "class" => type.back_type.to_s, "ivars" => type.ivars.to_h { |name, value| [name.to_s, sidecar_value(value)] } }
      end

      # How the sidecar writes what a body left its receiver holding
      # (`ObjectStates::Exit`).
      def sidecar_exit(exit)
        ivars = ->(values) { values.to_h { |name, value| [name.to_s, sidecar_value(sidecar_writable(value))] } }
        written = { "ivars" => ivars.(exit.ivars) }
        written["classes"] = exit.classes.to_h { |name, values| [name.to_s, ivars.(values)] } unless exit.classes.empty?
        written["params"] = ivars.(exit.params) unless exit.params.empty?
        written["keeps_self"] = true if exit.keeps_self
        written
      end

      # `type` with every literal replaced by the class it instantiates. The
      # widening operator of the fixpoint: a value that keeps changing is a value
      # the program does not fix, and its class is what it does fix.
      def widen_literals(type)
        return type.back_type if type.is_a?(AST::Types::Literal)

        type.map_type { |child| widen_literals(child) }
      end

      # `"Foo#bar"` / `"Foo.bar"` for a resolved call, matching how a `def` in the
      # source keys itself. nil when the call resolves to more than one
      # declaration — the argument tuple then names no single body to specialize.
      def method_key(method_decls)
        return nil unless method_decls.size == 1

        method_decls.first.method_name.to_s.delete_prefix("::")
      end

      # What a parameter holds in a body checked under `arguments`. The block
      # parameter holds what the call passed: nothing, or a block.
      def param_type(param, arguments)
        return param.var_type unless arguments && param.is_a?(TypeInference::MethodParams::BlockParameter)
        return AST::Builtin.nil_type unless arguments.block
        return param.var_type unless param.type

        AST::Types::Proc.new(type: param.type, block: nil, self_type: param.self_type)
      end
    end

    # The argument types of one call, in the spelling both sides key on.
    class Arguments
      attr_reader :positionals, :keywords

      # What a keyword rest parameter collects at this call: the keywords no
      # other parameter names, as the record they build — `{  }` where the
      # call passes none, since the body then holds exactly that. nil where
      # the method takes no keyword rest.
      attr_reader :keyword_rest

      # The argument types of `node`, or nil when the call has a shape no tuple
      # describes: a splat, a block pass that may or may not be a block, a
      # non-symbol keyword.
      #
      # A call fixing no literal is still described. Specializing its RETURN
      # would only record the declaration back, so `Collector.call_sites` drops
      # it — but a body that writes code is decided by its defaults and its
      # control flow as much as by its arguments, and `slot()` with a literal
      # default is as determined as `slot(:ro)`.
      # `receiver_ivars`: what the receiver's contents are known to be
      # (`receiver_ivars`), read off the call where it is recorded already and
      # off the checker where it is being typed.
      def self.from_send(node, typing, call:, receiver_ivars:, class_states:, self_type:, exact_self:)
        block, node = node, node.children[0] if Accumulators::LAMBDA_BODIES.include?(node.type)
        _receiver, name, *args = node.type == :super ? [nil, nil, *node.children] : node.children
        # `send(:name, …)` resolved to `name`: the literal names the method,
        # and the arguments are the rest (`TypeConstruction::SendDispatch`).
        args = args.drop(1) if TypeConstruction::SEND_SPELLINGS.key?(name) && dispatched?(node, typing)

        if args.last&.type == :block_pass
          passed = passed_block(args.pop, typing)
          return nil if passed.nil?

          block = passed if passed
        end

        keywords = args.last&.type == :kwargs ? keyword_types(args.pop, typing, exact_self) : {}
        return nil unless keywords

        positionals = [] #: Array[AST::Types::t]
        args.each do |arg|
          return nil if arg.type == :splat
          return nil unless typing.has_type?(arg)

          positionals << argument_type(arg, typing, exact_self)
        end

        new(
          positionals: positionals, **split_keyword_rest(call, keywords), self_ivars: receiver_ivars, class_states: class_states, self_type: self_type, block: block,
          narrows_classes: narrows_classes?(call, positionals, keywords)
        )
      end

      # Whether an argument is an instance of a class narrower than the
      # parameter it lands in: a call passing a `Counter` where `Counter |
      # Printer` is declared fixes which visitor the body calls back.
      def self.narrows_classes?(call, positionals, keywords)
        params = call.is_a?(TypeInference::MethodCall::Typed) ? call.actual_method_type.type.params : nil
        return false unless params

        declared = [] #: Array[AST::Types::t]
        params.positional_params&.each do |param|
          break if param.is_a?(Interface::Function::Params::PositionalParams::Rest)

          declared << param.type
        end
        keyword_params = params.keyword_params
        pairs = positionals.zip(declared) + keywords.map { |name, type| [type, keyword_params.requireds[name] || keyword_params.optionals[name]] }
        pairs.any? { |type, param| narrower_class?(type, param) }
      end

      def self.narrower_class?(type, declared)
        type = ObjectStates.state_in(type)&.back_type || type
        return false unless type.is_a?(AST::Types::Name::Instance)

        case declared
        when AST::Types::Union then declared != type
        when AST::Types::Name::Instance then declared.name != type.name
        else false
        end
      end

      # The keywords a call writes, by name, or nil where one is not a plain
      # `name: value` pair.
      def self.keyword_types(kwargs, typing, exact_self)
        kwargs.children.each_with_object({}) do |pair, keywords| #$ Hash[Symbol, AST::Types::t]
          return nil unless pair.type == :pair

          key, value = pair.children
          return nil unless key.type == :sym && typing.has_type?(value)

          keywords[key.children[0]] = argument_type(value, typing, exact_self)
        end
      end

      # What a `&value` hands the callee, when the call fixes it: `false` for
      # no block at all, the `block_pass` itself for a block whose body is not
      # known here. nil when `value` may or may not be one.
      def self.passed_block(block_pass, typing)
        return nil unless typing.has_type?(block_pass)

        type = typing.type_of(node: block_pass)
        return false if type.is_a?(AST::Types::Nil)

        block_pass unless type.is_a?(AST::Types::Union) && type.types.any? { |member| member.is_a?(AST::Types::Nil) }
      end

            def self.split_keyword_rest(call, keywords)
        method_type = call.is_a?(TypeInference::MethodCall::Typed) ? call.actual_method_type : nil
        params = method_type&.type&.params&.keyword_params
        return { keywords: keywords } unless params&.rest

        named, rest = keywords.partition { |name, _| params.requireds.key?(name) || params.optionals.key?(name) }.map(&:to_h)
        { keywords: named, keyword_rest: AST::Types::Record.new(elements: rest, required_keys: rest.keys.to_set) }
      end

      # The class a call's receiver is, where it names exactly one, as a class
      # object or as an instance:
      #
      #   class Base
      #     def self.generated_methods = const_set(:GeneratedMethods, Module.new)
      #     def introduce = speak("hello")
      #   end
      #
      #   Widget.generated_methods   # Widget::GeneratedMethods, not Base's
      #   Base.generated_methods     # Base::GeneratedMethods
      #   Dog.new.introduce          # Dog#speak, not Cat's
      def self.receiver_self(call, exact_self)
        return nil unless call.is_a?(TypeInference::MethodCall::Typed) && call.method_decls.size == 1

        receiver = call.receiver_type
        receiver = exact_self if receiver.is_a?(AST::Types::Self)
        receiver = ObjectStates.state_in(receiver)&.back_type || receiver
        return nil unless receiver.is_a?(AST::Types::Name::Singleton) || receiver.is_a?(AST::Types::Name::Instance)

        receiver
      end

      def self.dispatched?(node, typing)
        typing.call_of(node: node).method_name != node.children[1]
      rescue Typing::UnknownNodeError
        false
      end

      # The value an argument written as a literal is, whatever the parameter
      # it lands in is declared: an `untyped` one would otherwise widen it at
      # the call, and the call fixes the value all the same.
      def self.written_literal(arg, typing)
        case arg.type
        when :str, :sym, :int
          value = arg.children[0]
          AST::Types::Literal.new(value: value) if value.is_a?(::String) || value.is_a?(::Symbol) || value.is_a?(::Integer)
        when :regexp
          LiteralSyntax.regexp(arg, typing)
        end
      end

      # The ivars of the object the call is made on whose contents are known
      # (`AST::Types::ObjectState`): `self`'s where the call is made on it
      # (`Typing#self_ivars_of_call`), a class object's where a class body left
      # them known (`class_states`), the receiver's state's otherwise.
      def self.receiver_ivars(receiver_type, self_ivars, class_states)
        return self_ivars if receiver_type.is_a?(AST::Types::Self)
        return class_states.fetch(receiver_type.name, {}) if receiver_type.is_a?(AST::Types::Name::Singleton)

        state = receiver_type.is_a?(AST::Types::Intersection) ? receiver_type.types.grep(AST::Types::ObjectState).first : receiver_type
        state.is_a?(AST::Types::ObjectState) ? state.ivars : {}
      end

      # A `super` runs on `self`, whatever type its call is resolved on.
      def self.receiver_of(node, call)
        node.type == :super ? AST::Types::Self.instance : call.receiver_type
      end

      def self.recorded_receiver_ivars(node, typing)
        receiver_ivars(receiver_of(node, typing.call_of(node: node)), typing.self_ivars_of_call(node: node), typing.class_states_of_call(node: node))
      rescue Typing::UnknownNodeError
        {}
      end

      # The arguments of `call`, being typed at `node`, keyed under what the
      # checker knows there.
      def self.at_call(node, typing, call, self_ivars:, class_states:, keyed_self:, exact_self:)
        from_send(
          node, typing, call: call,
          receiver_ivars: receiver_ivars(receiver_of(node, call), self_ivars, class_states),
          class_states: callee_class_states(call, class_states),
          self_type: keyed_self, exact_self: exact_self
        )
      end

      # The arguments of the call recorded at `node`, keyed under what the
      # checker knew there.
      def self.recorded(node, typing)
        call = typing.call_of(node: node)
        from_send(
          node, typing, call: call,
          receiver_ivars: recorded_receiver_ivars(node, typing),
          class_states: callee_class_states(call, typing.class_states_of_call(node: node)),
          self_type: typing.keyed_self_of_call(node: node), exact_self: typing.exact_self_of_call(node: node)
        )
      rescue Typing::UnknownNodeError
        nil
      end

      # The class states a callee is checked under, but its receiver's own:
      # those it starts from as `self_ivars`.
      def self.callee_class_states(call, class_states)
        receiver_type = call.is_a?(TypeInference::MethodCall::Typed) ? call.receiver_type : nil
        receiver_type.is_a?(AST::Types::Name::Singleton) ? class_states.except(receiver_type.name) : class_states
      end

      # The type a call site keys this argument on. A tuple stands for the
      # contents a callee's parameter ARRIVES holding (`Arrived`), so it is only
      # kept where those contents are known: an array written at this very
      # argument, or one the checker vouched for — a local where it was handed
      # on, a call whose value the checker computed rather than read off its
      # declaration (`TypeConstruction#record_built_value`). A tuple that is only
      # a TYPE — a local annotated with one, a method declared to return one —
      # says nothing about what the array holds now, and is widened to the array
      # it describes:
      #
      #   # @type var parts: ["a", "b"]
      #   parts.reverse!
      #   fill(parts)          # ["b", "a"] at runtime
      #
      # `self`, where the call's body is checked for one class (`exact_self`),
      # is that class: the callee would read `self` as its own receiver.
      def self.argument_type(arg, typing, exact_self)
        written = written_literal(arg, typing) || written_record(arg, typing, exact_self) and return written
        type = typing.type_of(node: arg)
        type = type.subst(Interface::Substitution.build([], self_type: exact_self)) if exact_self
        vouched = typing.vouched_of(node: arg)
        # A local is vouched for IN PLACE of its declared type; a call only while
        # its type is still the one the checker computed.
        return vouched if vouched && (arg.type == :lvar || vouched == type)

        case type
        when AST::Types::Tuple
          return type if arg.type == :array

          AST::Builtin::Array.instance_type(union_or_untyped(type.types))
        when AST::Types::Record
          keys = type.elements.keys.map { |key| AST::Types::Literal.new(value: key) }
          AST::Builtin::Hash.instance_type(union_or_untyped(keys), union_or_untyped(type.elements.values))
        else
          type
        end
      end

      def self.union_or_untyped(types)
        types.empty? ? AST::Builtin.any_type : AST::Types::Union.build(types: types)
      end

      # A hash written at the argument, as the record it is: every key it has,
      # and no other. The checker types `{ through: :posts }` as a record only
      # where the parameter asks for one, and `{}` as `Hash[untyped, untyped]`.
      def self.written_record(arg, typing, exact_self)
        return nil unless arg.type == :hash

        elements = {} #: Hash[AST::Types::Record::key, AST::Types::t]
        arg.children.each do |pair|
          return nil unless pair.type == :pair

          key, value = pair.children
          return nil unless %i[sym str int].include?(key.type) && typing.has_type?(value)

          elements[key.children[0]] = argument_type(value, typing, exact_self)
        end

        AST::Types::Record.new(elements: elements, required_keys: elements.keys.to_set)
      end

      def initialize(positionals:, keywords:, self_ivars:, class_states:, keyword_rest: nil, positional_defaults: {}, keyword_defaults: {}, self_type: nil, block: nil, narrows_classes: false)
        @positionals = positionals
        @narrows_classes = narrows_classes
        @block = block
        @keywords = keywords
        @keyword_rest = keyword_rest
        @positional_defaults = positional_defaults
        @keyword_defaults = keyword_defaults
        @self_type = self_type
        @self_ivars = self_ivars
        @class_states = class_states
      end

      # The `self` the body runs with at this call site, or nil for the one its
      # definition gives it.
      #
      # A macro inherited by a subclass runs there with `self` being the
      # subclass, and what it reflects on is then the subclass too:
      #
      #   class Peel;      def self.macro(m) = Writer.generate(self, m); end
      #   class Rind < Peel; macro :nick; end    # `self` is Rind, not Peel
      #
      # Only the call site says so, so it is part of what keys the call — and
      # unlike `defaults`, it is part of `==`: two call sites passing the same
      # arguments from two classes run the body twice.
      #
      # It is part of `key` too, so a return recorded under it is read back only
      # by a call on that class (`receiver_self`).
      attr_reader :self_type

      # The ivars of the receiver whose contents the caller knew
      # (`receiver_ivars`). The body is checked starting from them, and they
      # are part of `key`, so only a caller that knows the same contents reads
      # back what was recorded under them.
      attr_reader :self_ivars

      # The states of class objects the caller knew and the body may read
      # (`ObjectStates::ClassStates`): part of `key` for the same reason.
      attr_reader :class_states

      # The block written at the call: part of `key`, since what the body
      # leaves depends on it, and what a `yield` checks in place
      # (`ObjectStates::Yields`).
      attr_reader :block

      # The one every class shares is the one a declaration can hold.
      def tuples
        [self, (without_self if self_type)].compact.select(&:literal?)
      end

      def without_self
        with_self(nil)
      end

      # One `Arguments` per choice a union of literals leaves open: a call
      # passing `(:posts | :categories)` passes one of `(:posts)`, `(:categories)`.
      def alternatives
        choices = [*positionals, *keywords.values].map { |type| LiteralIntrinsics.literal_union?(type) ? type.types : [type] }
        choices.empty? ? [self] : choices.first.product(*choices.drop(1)).map { |values| with_values(values) }
      end

      def with_values(values)
        Arguments.new(
          positionals: values.take(positionals.size),
          keywords: keywords.keys.zip(values.drop(positionals.size)).to_h,
          keyword_rest: @keyword_rest,
          positional_defaults: @positional_defaults,
          keyword_defaults: @keyword_defaults,
          self_type: @self_type,
          self_ivars: @self_ivars,
          class_states: @class_states,
          block: @block,
          narrows_classes: @narrows_classes
        )
      end

      def with_self(self_type)
        Arguments.new(
          positionals: @positionals,
          keywords: @keywords,
          keyword_rest: @keyword_rest,
          positional_defaults: @positional_defaults,
          keyword_defaults: @keyword_defaults,
          self_type: self_type,
          self_ivars: @self_ivars,
          class_states: @class_states,
          block: @block,
          narrows_classes: @narrows_classes
        )
      end

      def with_self_ivars(self_ivars)
        Arguments.new(
          positionals: @positionals,
          keywords: @keywords,
          keyword_rest: @keyword_rest,
          positional_defaults: @positional_defaults,
          keyword_defaults: @keyword_defaults,
          self_type: @self_type,
          self_ivars: self_ivars,
          class_states: @class_states,
          block: @block,
          narrows_classes: @narrows_classes
        )
      end

      # The same arguments with every `self` among them read as `self_type`.
      #
      # A `self` argument is typed `self`, a variable the CALLEE would bind to
      # its own receiver: `Writer.generate(self, name)` handed on as written
      # makes `owner` the `Writer` that `generate` is defined on. What was
      # handed is the caller's self, so it is resolved in the caller's frame.
      def resolve_self(self_type)
        substitution = Interface::Substitution.build([], self_type: self_type)

        Arguments.new(
          positionals: @positionals.map { |type| type.subst(substitution) },
          keywords: @keywords.transform_values { |type| type.subst(substitution) },
          keyword_rest: @keyword_rest&.subst(substitution),
          positional_defaults: @positional_defaults,
          keyword_defaults: @keyword_defaults,
          self_type: @self_type,
          self_ivars: @self_ivars,
          class_states: @class_states,
          block: @block,
          narrows_classes: @narrows_classes
        )
      end

      # The same call, with the parameters it leaves out fixed to the values the
      # definition gives them. A call that omits an optional does not leave that
      # parameter open — it runs the body with the default, which is exactly the
      # kind of fact a per-call-site check exists to use.
      #
      # `defaults` stays out of `key`, `==` and `hash`: they are a property of
      # the DEFINITION, so two calls that spell the same tuple cannot disagree
      # about them, and the send side computes its key from the call alone.
      def with_defaults(positionals: {}, keywords: {})
        Arguments.new(
          positionals: @positionals,
          keywords: @keywords,
          keyword_rest: @keyword_rest,
          positional_defaults: positionals,
          keyword_defaults: keywords,
          self_type: @self_type,
          self_ivars: @self_ivars,
          class_states: @class_states,
          block: @block,
          narrows_classes: @narrows_classes
        )
      end

      def key
        key = arguments_key
        key += "#{SELF_MARKER}#{self_type}" if self_type
        key += "#{BLOCK_MARKER}#{block_key}" if block
        return key unless stateful?

        "#{key}#{STATE_MARKER}#{[*ivars_key(self_ivars), *class_states_key].join(", ")}}"
      end

      def argument_types
        [*positionals, *keywords.values, keyword_rest].compact
      end

      def arguments_key
        parts = positionals.map(&:to_s)
        parts.concat(keywords.keys.sort.map { |name| "#{name}: #{keywords[name]}" })
        parts << "**#{keyword_rest}" if keyword_rest
        "(#{parts.join(", ")})"
      end

      def ivars_key(ivars)
        ivars.sort_by(&:first).map { |name, type| "#{name}: #{type}" }
      end

      def class_states_key
        class_states.sort_by { |name, _| name.to_s }.map { |name, ivars| "#{name}{#{ivars_key(ivars).join(", ")}}" }
      end

      # Where a key goes on to name the receiver's contents. The check that
      # reads it back computes the same contents where it types the call.
      STATE_MARKER = " with {"

      SELF_MARKER = " on "

      BLOCK_MARKER = " &"

      def self.persistable_key?(key)
        !key.include?(BLOCK_MARKER)
      end

      def block_key
        expression = block.loc.expression
        "#{expression.source_buffer.name}:#{expression.begin_pos}"
      end

      def stateful?
        !self_ivars.empty? || !class_states.empty?
      end

      # Whether the call hands the body a record, whose exit says what the
      # caller's local holds after it (`HashMutation.param_exits`).
      def hands_records?
        [*positionals, *keywords.values].any?(AST::Types::Record)
      end

      def literal?
        stateful? || !self_type.nil? || fixes_a_value?
      end

      def fixes_a_value?
        @narrows_classes || !keyword_rest.nil? || positionals.any? { |type| literal_type?(type) } || keywords.each_value.any? { |type| literal_type?(type) }
      end

      def empty?
        positionals.empty? && keywords.empty?
      end

      # `method_type` with each parameter this call fixed replaced by the type it
      # was passed. Parameters the call leaves to their default keep the declared
      # type; a positional past a rest parameter is left alone, because the index
      # no longer names one parameter.
      def substitute(method_type)
        function = method_type.type
        return method_type unless function.is_a?(Interface::Function)

        params = function.params.update(
          positional_params: substitute_positionals(function.params.positional_params),
          keyword_params: substitute_keywords(function.params.keyword_params)
        )

        method_type.with(type: function.with(params: params))
      end

      # What parameter `name` of `def_node` arrives holding at this call, as a
      # tuple, or nil where that is not a collection this call fixes.
      def arrived(def_node, name)
        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        return nil unless args.is_a?(::Parser::AST::Node)

        params = args.children
        index = params.index { |param| %i[arg restarg kwarg].include?(param.type) && param.children[0] == name } or return nil
        return rest_tuple(def_node) if params[index].type == :restarg

        if params[index].type == :kwarg
          type = keywords[name]
          return type.is_a?(AST::Types::Tuple) ? type : nil
        end

        required = %i[arg mlhs]
        type =
          if params[0...index].all? { |param| required.include?(param.type) }
            positionals[index]
          else
            # After an optional or the rest, a required positional takes its
            # argument counted from the END.
            from_end = params[(index + 1)..].count { |param| required.include?(param.type) }
            positionals[positionals.size - 1 - from_end] if positionals.size > from_end
          end

        type if type.is_a?(AST::Types::Tuple)
      end

      # The arguments that land in `def_node`'s positional rest parameter, as a
      # tuple — or nil where it has none, or this call does not reach it.
      #
      # The parameter's TYPE can only say what each element is. The call also
      # says how many there are and in which order, and it BUILDS the array, so
      # what the body is handed is exactly those:
      #
      #   def delegate(*methods, to:)          # Array[Symbol] by type
      #   delegate :email, :name, to: :user    # [:email, :name] at this call
      #
      # Read off the definition rather than the method type, which has no place
      # for a positional AFTER the rest. Ruby fills the required ones on both
      # sides first, then the optionals in order, and the rest takes what is
      # left between them.
      def rest_tuple(def_node)
        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        return nil unless args.is_a?(::Parser::AST::Node)

        params = args.children
        rest_index = params.index { |param| param.type == :restarg } or return nil
        positional = %i[arg optarg mlhs]

        leading = params[0...rest_index].count { |param| param.type == :arg || param.type == :mlhs }
        optional = params[0...rest_index].count { |param| param.type == :optarg }
        trailing = params[(rest_index + 1)..].count { |param| positional.include?(param.type) }

        free = positionals.size - leading - trailing
        return nil if free.negative?

        filled = [optional, free].min
        AST::Types::Tuple.new(types: positionals[leading + filled, free - filled] || [])
      end

      def ==(other)
        other.is_a?(Arguments) && other.positionals == positionals && other.keywords == keywords && other.keyword_rest == keyword_rest &&
          other.self_type == self_type && other.self_ivars == self_ivars && other.class_states == class_states && other.block.equal?(block)
      end

      alias eql? ==

      def hash
        positionals.hash ^ keywords.hash ^ keyword_rest.hash ^ self_type.hash ^ self_ivars.hash ^ class_states.hash ^ block.object_id.hash
      end

      private

      # A tuple, a record or an object whose ivars are known fixes an argument
      # as surely as a literal does — it is only ever one whose contents are
      # known (`argument_type`).
      def literal_type?(type)
        [AST::Types::Literal, AST::Types::Tuple, AST::Types::Record, AST::Types::ObjectState].any? { |klass| type.is_a?(klass) }
      end

      # A positional index names one parameter only up to the first rest
      # parameter. What lands in the REST is everything left, and a call site
      # fixes those as surely as it fixes a required one:
      #
      #   def delegate(*methods, to:)   # methods: Array[Symbol]
      #   delegate :email, to: :user    # methods: Array[:email]
      #
      # The element type is the union of what is left, which is what the array
      # holds — sound for any number of them, and a literal for the one-argument
      # case that a macro's interpolation can then fold. A rest param left at its
      # declaration says `Symbol`, and `"def #{name}"` over that is `::String`.
      def substitute_positionals(params)
        return params unless params

        index = 0
        params.map do |param|
          case param
          when Interface::Function::Params::PositionalParams::Required,
               Interface::Function::Params::PositionalParams::Optional
            type = positionals[index] || @positional_defaults[index]
            index += 1
            type ? param.map_type { type } : param
          when Interface::Function::Params::PositionalParams::Rest
            rest = positionals[index..] || []
            index = positionals.size
            rest.empty? ? param : param.map_type { union_of(rest) }
          else
            index = positionals.size
            param
          end
        end
      end

      def union_of(types)
        types.size == 1 ? types.fetch(0) : AST::Types::Union.build(types: types)
      end

      def substitute_keywords(params)
        return params if keywords.empty? && @keyword_defaults.empty?

        params.update(
          requireds: substitute_keyword_hash(params.requireds),
          optionals: substitute_keyword_hash(params.optionals)
        )
      end

      def substitute_keyword_hash(hash)
        hash.each_key.with_object({}) do |name, result|
          result[name] = keywords.fetch(name) { @keyword_defaults.fetch(name, hash[name]) }
        end
      end
    end

    class Store
      attr_reader :methods, :source, :active

      def self.empty
        new(methods: {}, source: nil, receivers: {})
      end

      # `base_dir`: what the sites under `receivers` are relative to.
      def self.from_hash(raw, source:, base_dir:)
        version = raw && raw["version"]
        if version && version != SCHEMA_VERSION
          Steep.logger.warn { "[specializations] unsupported sidecar version #{version} (expected #{SCHEMA_VERSION}); ignoring #{source}" }
          return empty
        end

        methods = {} #: Hash[String, Hash[String, String]]
        ((raw && raw["methods"]) || {}).each do |method_key, entries|
          next unless entries.is_a?(Hash)

          methods[method_key] = entries.select { |key, type| key.is_a?(String) && (type.is_a?(String) || type.is_a?(Hash)) }
        end

        declarations = ((raw && raw["declarations"]) || {}).select { |key, type| key.is_a?(String) && type.is_a?(String) }
        receivers = ((raw && raw["receivers"]) || {}).filter_map do |site, types|
          [File.expand_path(site, base_dir.to_s), types] if site.is_a?(String) && types.is_a?(Array) && types.all?(String)
        end.to_h
        exits = ((raw && raw["exits"]) || {}).select { |key, entries| key.is_a?(String) && entries.is_a?(Hash) }

        new(methods: methods, source: source, declarations: declarations, receivers: receivers, exits: exits)
      end

      # `typed`: returns a run computed, as types, read ahead of `methods`.
      # `exits`: the ivars a body left its receiver holding, under a key that
      # names what it held on entry (`Arguments#stateful?`).
      # `demand`: checks the body for an exit not recorded yet, there and then.
      # `class_exits`: the hash memos each class body left holding
      # (`Typing#class_exits`).
      # `declarations`: what each method answers across all its calls
      # (`CallSiteUnions`), as RBS.
      # `receivers`: the types the receiver of each call naming a reader was
      # given (`Receivers`), as RBS, by site.
      # `reads`: where to record each question a check asks and the answer it
      # got (`Reads`).
      def initialize(methods:, source:, active: {}, typed: {}, exits: {}, demand: nil, class_exits: {}, declarations: {}, receivers:, reads: nil)
        @methods = methods
        @receivers = receivers
        @declarations = declarations
        @memo = {}.compare_by_identity
        @source = source
        @active = active
        @typed = typed
        @exits = exits
        @demand = demand
        @class_exits = class_exits
        @reads = reads
      end

      def empty?
        read(:empty?) { @methods.empty? && @active.empty? && @typed.empty? && @exits.empty? && @declarations.empty? }
      end

      # `in_checked_body`: whether the call is made in a body this check is
      # specializing, rather than elsewhere in its file.
      def exit_ivars(method_key, arguments, in_checked_body:, factory:)
        read(:exit_ivars, method_key, arguments, in_checked_body: in_checked_body, factory: factory) do
          exit = @exits.dig(method_key, arguments.key)
          exit = parse_exit(method_key, exit, factory: factory) if exit.is_a?(Hash)
          exit || @demand&.call(self, method_key, arguments, in_checked_body)
        end
      end

      # Whether the body `method_key` was checked under `argument_key` kept
      # `self` (`ObjectStates::KeptSelf`).
      def keeps_self?(method_key, argument_key)
        read(:keeps_self?, method_key, argument_key) do
          exit = @exits.dig(method_key, argument_key)
          (exit.is_a?(Hash) ? exit["keeps_self"] : exit&.keeps_self) == true
        end
      end

      def receiver_type(site, factory:)
        read(:receiver_type, site, factory: factory) do
          types = @receivers[site]&.map { |raw| parse(site, raw, factory: factory) or break nil }
          types && AST::Types::Union.build(types: types)
        end
      end

      def class_exit(name, ivar)
        read(:class_exit, name, ivar) { @class_exits.dig(name, ivar) }
      end

      # The recorded return type for `method_key` called with `argument_key`, as a
      # Steep type, or nil when nothing was recorded or the entry no longer parses.
      #
      # A union of literals passed in an argument is one of its members at run
      # time, so the call returns what one of those returned.
      def call_return_type(method_key, arguments, factory:)
        read(:call_return_type, method_key, arguments, factory: factory) do
          types = arguments.alternatives.map do |alternative|
            return_type(method_key, alternative.key, factory: factory) ||
              (alternative.self_type && return_type(method_key, alternative.without_self.key, factory: factory)) ||
              (break nil)
          end

          types && AST::Types::Union.build(types: types)
        end
      end

      def return_type(method_key, argument_key, factory:)
        typed = @typed.dig(method_key, argument_key) and return typed
        parse(method_key, @methods.dig(method_key, argument_key), factory: factory)
      end

      def declaration_type(method_key, factory:)
        read(:declaration_type, method_key, factory: factory) { parse(method_key, @declarations[method_key], factory: factory) }
      end

      # `yield`, computed once per `object` for as long as this store is the
      # one being checked under.
      def memoize(object)
        return @memo[object] if @memo.key?(object)

        @memo[object] = yield
      end

      def parse(method_key, raw, factory:)
        return nil unless raw
        return parse_state(method_key, raw, factory: factory) if raw.is_a?(Hash)

        factory.type(RBS::Parser.parse_type(raw).map_type_name { |name, _, _| name.absolute! })
      rescue RBS::ParsingError, RBS::BaseError => exn
        Steep.logger.warn { "[specializations] unparsable type #{raw.inspect} for #{method_key}: #{exn.message}" }
        nil
      end

      def parse_exit(method_key, raw, factory:)
        values = ->(written) { (written || {}).to_h { |name, value| [name.to_sym, parse(method_key, value, factory: factory) || (return nil)] } }
        classes = (raw["classes"] || {}).to_h { |name, written| [RBS::TypeName.parse(name), values.(written) || (return nil)] }
        ivars = values.(raw["ivars"]) or return nil
        params = values.(raw["params"]) or return nil
        ObjectStates::Exit.new(
          ivars: ivars, classes: classes, params: params.transform_keys { |slot| slot.match?(/\A\d+\z/) ? slot.to_s.to_i : slot },
          keeps_self: raw["keeps_self"] == true || nil
        )
      end

      def parse_state(method_key, raw, factory:)
        back_type = parse(method_key, raw["class"], factory: factory)
        ivars = (raw["ivars"] || {}).to_h { |name, value| [name.to_sym, parse(method_key, value, factory: factory)] }
        return nil unless back_type.is_a?(AST::Types::Name::Instance) && ivars.each_value.all?

        AST::Types::ObjectState.new(back_type: back_type, ivars: ivars)
      end

      # The argument types a specialization pass is currently checking one BODY
      # under — nil during an ordinary type check, where every body is checked
      # once under its declaration.
      #
      # Keyed by the `def` node (its file and its offset), not by the method's
      # name. A name has to be derived from the self type at the point the body
      # is checked, and the two part company exactly where this matters: a
      # concern's `ClassMethods` is written as an instance method and reached as
      # a singleton one, so a `@type instance:` annotation names the host and not
      # the module the body is written in. The node is what the pass asked about.
      def active_arguments(node_key)
        @active[node_key]
      end

      def with_active(active) = with(active: active, reads: @reads)

      def with_reads(reads) = with(active: @active, reads: reads)

      # Asks `name` again with what it was asked, for `Reads#same?`.
      def answer(name, arguments, options) = public_send(name, *arguments, **options)

      private

      def with(active:, reads:)
        Store.new(
          methods: @methods, source: @source, active: active, typed: @typed, exits: @exits, demand: @demand,
          class_exits: @class_exits, declarations: @declarations, receivers: @receivers, reads: reads
        )
      end

      def read(name, *arguments, **options)
        answer = yield
        @reads&.record(name, arguments, options, answer)
        answer
      end
    end
  end
end
