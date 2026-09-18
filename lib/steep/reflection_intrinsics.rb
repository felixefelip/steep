module Steep
  # Reflection answered out of the DECLARATION the checker already has.
  #
  # `LiteralIntrinsics` folds by running the core method over the values it was
  # handed; nothing here runs anything. `receiver_class.public_instance_method(
  # :human_name).parameters` asks for exactly what
  # `def self.human_name: ("all" index) -> ::String` states, and a checker that
  # cannot answer it is declining to read its own signature
  # (felixefelip/steep#171).
  #
  # Three calls, in the order `ActiveSupport::Delegation` makes them:
  #
  #   owner.singleton_class                    # singleton_class(::Peel)
  #        .public_instance_method(:human_name) # unbound_method(::Peel.human_name)
  #        .parameters                          # [[:req, :index]]
  #
  # The chain breaks at the FIRST of those without this: `::Class` names no
  # module, so nothing downstream can say which method is being reflected on.
  #
  # Every gate `LiteralIntrinsics` applies applies here too — dispatch has
  # already succeeded against RBS, the call must resolve to one closed-table
  # core identity, and a project override disables the entry. What replaces
  # "every operand is a literal" is that the receiver must name one module
  # exactly, and the method it names must exist.
  #
  # Where the override registry stops is worth stating, because a reflection's
  # receiver can be any class rather than a core one. A project that redefines
  # `method` or `instance_method` and DECLARES it declines here by itself: the
  # call then resolves to that method's own key, which this table does not hold.
  # One written in Ruby and left undeclared is watched on the core classes
  # below, and outside them it is where it already was before this — Steep
  # dispatches against the signature either way, and the answer it gives is the
  # declaration's.
  module ReflectionIntrinsics
    # `method` is never CALLED. It is held for the same provenance check the
    # literal table makes — a key whose implementation is written in Ruby is one
    # this process cannot claim to model — and because asking for it is how the
    # table states that the method it is keyed by is the one Ruby ships.
    #
    # `shadowed_by` names the keys a REOPEN could answer this call with. A
    # method declared on `Kernel` is reached through every class between it and
    # the receiver, so `class Object; def singleton_class; …; end` runs instead
    # of the core one while dispatch still resolves to Kernel's. The entry's own
    # key says nothing about that, so it lists them and they are checked with
    # it — the same shape `LiteralIntrinsics`' `depends_on` has, for the other
    # way a key can stop describing what runs.
    Entry = _ = Struct.new(:method, :handler, :shadowed_by, keyword_init: true)

    # Every class a module or class object reaches BEFORE `Kernel`. Not
    # `BasicObject`, which the lookup reaches after it and so cannot shadow it.
    KERNEL_SHADOWS = ["::Object", "::Module", "::Class"].freeze

    # `Class < Module`, so a class object reaches a reopen of `Class` first.
    MODULE_SHADOWS = ["::Class"].freeze

    class << self
      def fold(call:, receiver_type:, argument_types:, factory:, override_registry:)
        key = MethodIdentity.key(call) or return nil
        entry = ENTRIES[key] or return nil
        return nil if override_registry.blocked?(key)
        return nil if entry.shadowed_by&.any? { |shadow| override_registry.blocked?(shadow) }
        source_location = entry.method.source_location
        return nil if source_location && !source_location.first.start_with?("<internal:")

        entry.handler.call(receiver_type, argument_types, factory)
      rescue StandardError => exn
        # Reflection is optional, so a bug here must not take down type
        # checking — but it must be visible.
        Steep.logger.warn do
          "[reflection_intrinsics] unexpected failure for #{key || "(unresolved)"}: #{exn.class}: #{exn.message}"
        end
        Steep.logger.debug { exn.full_message(highlight: false) }
        nil
      end

      # Every method key whose redefinition matters, for the override registry
      # to watch alongside the literal table's.
      def watched_keys
        @watched_keys ||= Set.new(
          ENTRIES.keys + ENTRIES.each_value.flat_map { |entry| entry.shadowed_by || [] }
        )
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end

      private

      # The method a reflection names, or nil when the declaration does not have
      # one: a module this cannot build, a name nothing declares (`NameError` at
      # runtime), or a private method asked for publicly.
      def method_definition(type, factory, public_only:)
        builder = factory.definition_builder
        definition =
          if type.singleton
            builder.build_singleton(type.type_name)
          else
            builder.build_instance(type.type_name)
          end

        method = definition.methods[type.method_name] or return nil
        return nil if public_only && !method.public?

        method
      rescue RBS::BaseError
        nil
      end

      # A module named exactly, on whichever side of it the call reflects.
      # `Foo.instance_method` reads Foo's instance methods; the same call on
      # `Foo.singleton_class` reads its class methods.
      def reflected_target(receiver)
        case receiver
        when AST::Types::MetaClass then [receiver.name, true]
        when AST::Types::Name::Singleton then [receiver.name, false]
        end
      end

      def literal_method_name(argument_types)
        return nil unless argument_types.size == 1

        type = argument_types.first
        return nil unless type.is_a?(AST::Types::Literal)

        value = type.value
        value.to_sym if value.is_a?(::Symbol) || value.is_a?(::String)
      end

      def unbound_method_object(receiver, argument_types, factory, public_only:)
        type_name, singleton = reflected_target(receiver)
        return nil unless type_name

        method_name = literal_method_name(argument_types) or return nil
        object = AST::Types::MethodObject.new(
          type_name: type_name, method_name: method_name, singleton: singleton, unbound: true
        )

        object if method_definition(object, factory, public_only: public_only)
      end

      # `method` is the bound half, and its receiver is a VALUE rather than the
      # module being reflected on: `Foo.method(:bar)` names a class method,
      # `foo.method(:bar)` an instance one. A metaclass declines — the methods
      # of a singleton class's own singleton class are a third object, which
      # nothing asks for.
      def bound_method_object(receiver, argument_types, factory)
        type_name, singleton =
          case receiver
          when AST::Types::Name::Singleton then [receiver.name, true]
          when AST::Types::Name::Instance then [receiver.name, false]
          end
        return nil unless type_name

        method_name = literal_method_name(argument_types) or return nil
        object = AST::Types::MethodObject.new(
          type_name: type_name, method_name: method_name, singleton: singleton, unbound: false
        )

        object if method_definition(object, factory, public_only: false)
      end

      # `Method#parameters`, read off the method type the declaration states.
      #
      # Declined for a method with more than one overload: `parameters` answers
      # for the one implementation Ruby has, and a signature written as several
      # method types does not say which of them describes it.
      def parameters(receiver, argument_types, factory)
        return nil unless argument_types.empty?
        return nil unless receiver.is_a?(AST::Types::MethodObject)

        method = method_definition(receiver, factory, public_only: false) or return nil
        return nil unless method.method_types.size == 1

        function = method.method_types.fetch(0).type
        return nil unless function.is_a?(RBS::Types::Function)

        AST::Types::Tuple.new(types: parameter_entries(function).map { |entry| entry_type(entry) })
      end

      def entry_type(entry)
        AST::Types::Tuple.new(types: entry.map { |value| AST::Types::Literal.new(value: value) })
      end

      # The pairs `Method#parameters` answers with, in Ruby's order.
      #
      # No `[:block, …]` entry: RBS states that a method TAKES a block, which is
      # not the same as its having been written with an `&blk` parameter, and
      # `parameters` reports the parameter. Reporting one the def may not have
      # would be inventing an answer rather than reading one.
      def parameter_entries(function)
        taken = declared_names(function)
        index = 0
        entries = [] #: Array[Array[Symbol]]

        emit = lambda do |kind, param|
          name = param.name || invented_name(index, taken)
          index += 1
          entries << [kind, name]
        end

        function.required_positionals.each { |param| emit[:req, param] }
        function.optional_positionals.each { |param| emit[:opt, param] }
        (rest = function.rest_positionals) && emit[:rest, rest]
        function.trailing_positionals.each { |param| emit[:req, param] }
        function.required_keywords.each { |name, _param| entries << [:keyreq, name] }
        function.optional_keywords.each { |name, _param| entries << [:key, name] }
        (rest_keywords = function.rest_keywords) && emit[:keyrest, rest_keywords]

        entries
      end

      def declared_names(function)
        names = ::Set.new #: Set[Symbol]
        function.each_param { |param| names << param.name if param.name }
        names.merge(function.required_keywords.keys)
        names.merge(function.optional_keywords.keys)
      end

      # RBS frequently declares a parameter without a name, and Ruby's own
      # `parameters` answers `[:req]` for one. A name is invented instead, so
      # that a consumer building a `def` line out of this gets the arity right —
      # which is what `ActiveSupport::Delegation` does with it, writing the
      # forwarding call from the same value. The folded source is then not
      # byte-identical to what Ruby writes at runtime, and that is the one place
      # this departs from reading.
      def invented_name(index, taken)
        candidate = :"arg#{index + 1}"
        candidate = :"#{candidate}_" while taken.include?(candidate)
        taken << candidate
        candidate
      end
    end

    SINGLETON_CLASS = lambda do |receiver, argument_types, _factory|
      next nil unless argument_types.empty?
      next nil unless receiver.is_a?(AST::Types::Name::Singleton)

      AST::Types::MetaClass.new(name: receiver.name)
    end
    INSTANCE_METHOD = lambda do |receiver, argument_types, factory|
      unbound_method_object(receiver, argument_types, factory, public_only: false)
    end
    PUBLIC_INSTANCE_METHOD = lambda do |receiver, argument_types, factory|
      unbound_method_object(receiver, argument_types, factory, public_only: true)
    end
    METHOD = lambda do |receiver, argument_types, factory|
      bound_method_object(receiver, argument_types, factory)
    end
    PARAMETERS = lambda do |receiver, argument_types, factory|
      parameters(receiver, argument_types, factory)
    end

    ENTRIES = {
      # `Kernel`'s, not `Object`'s — the table is keyed by what the call
      # RESOLVED to, and this is where the core declares it.
      "::Kernel#singleton_class" => Entry.new(
        method: ::Kernel.instance_method(:singleton_class), handler: SINGLETON_CLASS,
        shadowed_by: KERNEL_SHADOWS.map { |owner| "#{owner}#singleton_class" }
      ),
      "::Module#instance_method" => Entry.new(
        method: ::Module.instance_method(:instance_method), handler: INSTANCE_METHOD,
        shadowed_by: MODULE_SHADOWS.map { |owner| "#{owner}#instance_method" }
      ),
      "::Module#public_instance_method" => Entry.new(
        method: ::Module.instance_method(:public_instance_method), handler: PUBLIC_INSTANCE_METHOD,
        shadowed_by: MODULE_SHADOWS.map { |owner| "#{owner}#public_instance_method" }
      ),
      "::Kernel#method" => Entry.new(
        method: ::Kernel.instance_method(:method), handler: METHOD,
        shadowed_by: KERNEL_SHADOWS.map { |owner| "#{owner}#method" }
      ),
      "::Method#parameters" => Entry.new(
        method: ::Method.instance_method(:parameters), handler: PARAMETERS
      ),
      "::UnboundMethod#parameters" => Entry.new(
        method: ::UnboundMethod.instance_method(:parameters), handler: PARAMETERS
      )
    }.freeze
  end
end
