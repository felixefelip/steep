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
        Store.from_hash(raw, source: absolute.to_s)
      rescue Psych::Exception, LoadError => exn
        Steep.logger.warn { "[specializations] failed to parse #{absolute}: #{exn.message}" }
        Store.empty
      end

      # nil where `self` may be any subclass: in a class method checked under
      # its declaration rather than for one call site.
      # The class a call is specialized for: the one an inherited singleton
      # method runs on (`Arguments.inherited_self`), where its body may observe
      # which one that is (`ClassStates.reach`).
      def keyed_self(constr, call)
        receiver = Arguments.inherited_self(call, exact_self(constr)) or return nil
        receiver if ObjectStates::ClassStates.reach(constr, call).observes_self
      end

      # `call` with the return type recorded for the argument tuple this call site
      # supplies (felixefelip/rbs_infer#345, stage S4), or `call` unchanged.
      #
      # A call that takes a block is left alone: the recorded return was computed
      # for the arguments only, and a block can decide the return type on its own.
      def specialized_call(constr, node, call, block:)
        store = constr.specializations
        return call if store.empty? || block

        key = method_key(call.method_decls) or return call
        arguments = call_site_arguments(constr, node, call) or return call
        type = store.call_return_type(key, arguments, factory: constr.checker.factory) or return call

        call.with_return_type(type)
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
        return nil unless type.is_a?(AST::Types::Name::Singleton)

        method_context = constr.context.method_context or return type
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
    end

    # The argument types of one call, in the spelling both sides key on.
    class Arguments
      attr_reader :positionals, :keywords

      # The argument types of `node`, or nil when the call has a shape no tuple
      # describes: a splat, a block pass, a non-symbol keyword.
      #
      # A call fixing no literal is still described. Specializing its RETURN
      # would only record the declaration back, so `Collector.call_sites` drops
      # it — but a body that writes code is decided by its defaults and its
      # control flow as much as by its arguments, and `slot()` with a literal
      # default is as determined as `slot(:ro)`.
      # `receiver_ivars`: what the receiver's contents are known to be
      # (`receiver_ivars`), read off the call where it is recorded already and
      # off the checker where it is being typed.
      def self.from_send(node, typing, receiver_ivars:, class_states:, self_type:, exact_self:)
        _receiver, name, *args = node.children
        # `send(:name, …)` resolved to `name`: the literal names the method,
        # and the arguments are the rest (`TypeConstruction::SendDispatch`).
        args = args.drop(1) if TypeConstruction::SEND_SPELLINGS.key?(name) && dispatched?(node, typing)

        keywords = {} #: Hash[Symbol, AST::Types::t]
        if args.last&.type == :kwargs
          args.pop.children.each do |pair|
            return nil unless pair.type == :pair

            key, value = pair.children
            return nil unless key.type == :sym

            return nil unless typing.has_type?(value)

            keywords[key.children[0]] = argument_type(value, typing, exact_self)
          end
        end

        positionals = [] #: Array[AST::Types::t]
        args.each do |arg|
          return nil if arg.type == :splat || arg.type == :block_pass
          return nil unless typing.has_type?(arg)

          positionals << argument_type(arg, typing, exact_self)
        end

        new(positionals: positionals, keywords: keywords, self_ivars: receiver_ivars, class_states: class_states, self_type: self_type)
      end

      #   class Base
      #     def self.generated_methods = const_set(:GeneratedMethods, Module.new)
      #   end
      #
      #   Widget.generated_methods   # Widget::GeneratedMethods, not Base's
      def self.inherited_self(call, exact_self)
        return nil unless call.is_a?(TypeInference::MethodCall::Typed) && call.method_decls.size == 1

        receiver = call.receiver_type
        receiver = exact_self if receiver.is_a?(AST::Types::Self)
        return nil unless receiver.is_a?(AST::Types::Name::Singleton)

        receiver if call.method_decls.first.method_name.type_name != receiver.name
      end

      def self.dispatched?(node, typing)
        typing.call_of(node: node).method_name != node.children[1]
      rescue Typing::UnknownNodeError
        false
      end

      # The value an argument written as a literal is, whatever the parameter
      # it lands in is declared: an `untyped` one would otherwise widen it at
      # the call, and the call fixes the value all the same.
      def self.written_literal(arg)
        case arg.type
        when :str, :sym, :int
          value = arg.children[0]
          AST::Types::Literal.new(value: value) if value.is_a?(::String) || value.is_a?(::Symbol) || value.is_a?(::Integer)
        when :regexp
          *parts, flags = arg.children
          return unless parts.all? { |part| part.type == :str }

          options = flags.children.sum { |flag| TypeConstruction::REGEXP_OPTIONS.fetch(flag) { return } }
          AST::Types::RegexpLiteral.new(value: ::Regexp.new(parts.map { |part| part.children[0] }.join, options))
        end
      rescue RegexpError
        nil
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

      def self.recorded_receiver_ivars(node, typing)
        receiver_ivars(typing.call_of(node: node).receiver_type, typing.self_ivars_of_call(node: node), typing.class_states_of_call(node: node))
      rescue Typing::UnknownNodeError
        {}
      end

      # The arguments of `call`, being typed at `node`, keyed under what the
      # checker knows there.
      def self.at_call(node, typing, call, self_ivars:, class_states:, keyed_self:, exact_self:)
        from_send(
          node, typing,
          receiver_ivars: receiver_ivars(call.receiver_type, self_ivars, class_states),
          class_states: callee_class_states(call, class_states),
          self_type: keyed_self, exact_self: exact_self
        )
      end

      # The arguments of the call recorded at `node`, keyed under what the
      # checker knew there.
      def self.recorded(node, typing)
        call = typing.call_of(node: node)
        from_send(
          node, typing,
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
        written = written_literal(arg) and return written
        type = typing.type_of(node: arg)
        type = type.subst(Interface::Substitution.build([], self_type: exact_self)) if exact_self
        vouched = typing.vouched_of(node: arg)
        # A local is vouched for IN PLACE of its declared type; a call only while
        # its type is still the one the checker computed.
        return vouched if vouched && (arg.type == :lvar || vouched == type)

        return type unless type.is_a?(AST::Types::Tuple)
        return type if arg.type == :array

        AST::Builtin::Array.instance_type(type.types.empty? ? AST::Builtin.any_type : AST::Types::Union.build(types: type.types))
      end

      def initialize(positionals:, keywords:, self_ivars:, class_states:, positional_defaults: {}, keyword_defaults: {}, self_type: nil)
        @positionals = positionals
        @keywords = keywords
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
      # by a call on that class (`inherited_self`). No declaration can say
      # that, so such a key stays out of the sidecar, as a stateful one does.
      attr_reader :self_type

      # The ivars of the receiver whose contents the caller knew
      # (`receiver_ivars`). The body is checked starting from them, and they
      # are part of `key`, so only a caller that knows the same contents reads
      # back what was recorded under them.
      attr_reader :self_ivars

      # The states of class objects the caller knew and the body may read
      # (`ObjectStates::ClassStates`): part of `key` for the same reason.
      attr_reader :class_states

      # The one every class shares is the one a declaration can hold.
      def tuples
        [self, (without_self if self_type)].compact.select(&:literal?)
      end

      def without_self
        with_self(nil)
      end

      def with_self(self_type)
        Arguments.new(
          positionals: @positionals,
          keywords: @keywords,
          positional_defaults: @positional_defaults,
          keyword_defaults: @keyword_defaults,
          self_type: self_type,
          self_ivars: @self_ivars,
          class_states: @class_states
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
          positional_defaults: @positional_defaults,
          keyword_defaults: @keyword_defaults,
          self_type: @self_type,
          self_ivars: @self_ivars,
          class_states: @class_states
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
          positional_defaults: positionals,
          keyword_defaults: keywords,
          self_type: @self_type,
          self_ivars: @self_ivars,
          class_states: @class_states
        )
      end

      def key
        key = arguments_key
        key += "#{SELF_MARKER}#{self_type}" if self_type
        return key unless stateful?

        "#{key}#{STATE_MARKER}#{[*ivars_key(self_ivars), *class_states_key].join(", ")}}"
      end

      def arguments_key
        parts = positionals.map(&:to_s)
        parts.concat(keywords.keys.sort.map { |name| "#{name}: #{keywords[name]}" })
        "(#{parts.join(", ")})"
      end

      def ivars_key(ivars)
        ivars.sort_by(&:first).map { |name, type| "#{name}: #{type}" }
      end

      def class_states_key
        class_states.sort_by { |name, _| name.to_s }.map { |name, ivars| "#{name}{#{ivars_key(ivars).join(", ")}}" }
      end

      # Where a key goes on to name the receiver's contents. No sidecar holds
      # such a key: the contents have no RBS spelling, and only a run that
      # computed them can read them back.
      STATE_MARKER = " with {"

      SELF_MARKER = " on "

      def self.persistable_key?(key)
        !key.include?(STATE_MARKER) && !key.include?(SELF_MARKER)
      end

      def stateful?
        !self_ivars.empty? || !class_states.empty?
      end

      def literal?
        stateful? || !self_type.nil? || fixes_a_value?
      end

      def fixes_a_value?
        positionals.any? { |type| literal_type?(type) } || keywords.each_value.any? { |type| literal_type?(type) }
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
        other.is_a?(Arguments) && other.positionals == positionals && other.keywords == keywords &&
          other.self_type == self_type && other.self_ivars == self_ivars && other.class_states == class_states
      end

      alias eql? ==

      def hash
        positionals.hash ^ keywords.hash ^ self_type.hash ^ self_ivars.hash ^ class_states.hash
      end

      private

      # A tuple fixes an argument as surely as a literal does — it is only ever
      # one whose contents are known (`argument_type`).
      def literal_type?(type)
        type.is_a?(AST::Types::Literal) || type.is_a?(AST::Types::Tuple)
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
        new(methods: {}, source: nil)
      end

      def self.from_hash(raw, source:)
        version = raw && raw["version"]
        if version && version != SCHEMA_VERSION
          Steep.logger.warn { "[specializations] unsupported sidecar version #{version} (expected #{SCHEMA_VERSION}); ignoring #{source}" }
          return empty
        end

        methods = {} #: Hash[String, Hash[String, String]]
        ((raw && raw["methods"]) || {}).each do |method_key, entries|
          next unless entries.is_a?(Hash)

          methods[method_key] = entries.select { |key, type| key.is_a?(String) && type.is_a?(String) }
        end

        new(methods: methods, source: source)
      end

      # `typed`: returns a run computed, as types, read ahead of `methods`.
      # `exits`: the ivars a body left its receiver holding, under a key that
      # names what it held on entry (`Arguments#stateful?`).
      def initialize(methods:, source:, active: {}, typed: {}, exits: {})
        @methods = methods
        @source = source
        @active = active
        @typed = typed
        @exits = exits
      end

      def empty?
        @methods.empty? && @active.empty? && @typed.empty? && @exits.empty?
      end

      def exit_ivars(method_key, argument_key)
        @exits.dig(method_key, argument_key)
      end

      # The recorded return type for `method_key` called with `argument_key`, as a
      # Steep type, or nil when nothing was recorded or the entry no longer parses.
      def call_return_type(method_key, arguments, factory:)
        return_type(method_key, arguments.key, factory: factory) ||
          (arguments.self_type && return_type(method_key, arguments.without_self.key, factory: factory))
      end

      def return_type(method_key, argument_key, factory:)
        typed = @typed.dig(method_key, argument_key) and return typed
        raw = @methods.dig(method_key, argument_key) or return nil

        factory.type(RBS::Parser.parse_type(raw).map_type_name { |name, _, _| name.absolute! })
      rescue RBS::ParsingError, RBS::BaseError => exn
        Steep.logger.warn { "[specializations] unparsable type #{raw.inspect} for #{method_key}: #{exn.message}" }
        nil
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

      def with_active(active)
        Store.new(methods: @methods, source: @source, active: active, typed: @typed, exits: @exits)
      end
    end
  end
end
