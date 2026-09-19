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
  # A reflection's receiver is any class the project writes, not one of a fixed
  # core list, so the override check is receiver-aware: the fold walks the
  # LOOKUP CHAIN of the receiver, up to the class the entry is declared on, and
  # declines if the project redefines that name anywhere before it. That is what
  # `class Foo; def self.method(name); end` does to `Foo.method(:bar)` — Ruby
  # runs Foo's while dispatch still resolves to Kernel's, because a redefinition
  # the project DECLARES resolves to its own key and declines here by itself.
  #
  # Where that stops: a string eval whose receiver names no class, and a module
  # mixed in without the signatures recording it. Neither the ancestry nor the
  # registry can see those — the same boundary `LiteralMethodRegistry` already
  # draws.
  module ReflectionIntrinsics
    # `method` is never CALLED. It is held for the same provenance check the
    # literal table makes — a key whose implementation is written in Ruby is one
    # this process cannot claim to model — and because asking for it is how the
    # table states that the method it is keyed by is the one Ruby ships.
    #
    # `method` also carries the NAME the lookup chain is walked for, which is
    # why the entry holds the method object rather than just its key.
    Entry = _ = Struct.new(:method, :handler, keyword_init: true)

    # How many subclasses a reflected class may have before `parameters` stops
    # asking them and declines. A bound on the work rather than on the answer:
    # every one of them is read, so a class at the root of a large hierarchy —
    # `Object`, in the limit — is a question this will not spend a whole
    # program's definitions on.
    MAX_DESCENDANTS = 128

    class << self
      def fold(call:, receiver_type:, argument_types:, factory:, override_registry:)
        key = MethodIdentity.key(call) or return nil
        entry = ENTRIES[key] or return nil
        return nil if override_registry.blocked?(key)
        return nil if shadowed?(receiver_type, key, entry, factory, override_registry)
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
        @watched_keys ||= Set.new(ENTRIES.keys)
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end

      # The names a reflection is dispatched under. The registry records a
      # definition of one of these whoever writes it, because the class that
      # shadows a reflection is the receiver's, and the receiver is any class the
      # project has.
      def dispatched_names
        @dispatched_names ||= Set.new(ENTRIES.each_value.map { |entry| entry.method.name })
      end

      private

      # Whether the project redefines this call's method somewhere Ruby reaches
      # BEFORE the class the entry is declared on. The chain is the receiver's
      # own, in lookup order, so `extend`ed modules and superclasses count and
      # classes past the declaring one do not.
      #
      # A chain this cannot compute declines the fold: a receiver whose ancestry
      # is unknown is one whose implementation is unknown.
      def shadowed?(receiver_type, key, entry, factory, override_registry)
        return false if override_registry.empty?

        chain = dispatch_chain(receiver_type, entry.method.name, factory) or return true
        index = chain.index(key) or return true

        chain.take(index).any? { |candidate| override_registry.blocked?(candidate) }
      end

      # `method_name` keyed against every ancestor of the receiver, in the order
      # Ruby searches them. A `Singleton` ancestor is a class's own `def self.x`
      # and an `Instance` one is a method written in a class or a module body —
      # which is how a module `extend`ed into the receiver appears here.
      def dispatch_chain(receiver_type, method_name, factory)
        builder = factory.definition_builder.ancestor_builder
        ancestors =
          case receiver_type
          when AST::Types::Name::Singleton
            builder.singleton_ancestors(receiver_type.name)
          when AST::Types::MetaClass, AST::Types::MethodObject
            builder.instance_ancestors(receiver_type.back_type.name)
          end
        return nil unless ancestors

        ancestors.ancestors.map do |ancestor|
          separator = ancestor.is_a?(RBS::Definition::Ancestor::Singleton) ? "." : "#"
          "::#{ancestor.name.to_s.delete_prefix("::")}#{separator}#{method_name}"
        end
      rescue RBS::BaseError
        nil
      end

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
      # module being reflected on: `Foo.method(:bar)` names a class method.
      #
      # Only a class object, deliberately. `foo.method(:bar)` names an instance
      # method of whatever class `foo` turns out to be, and a nominal type does
      # not fix that: a subclass of the declared one may override `bar` with a
      # parameter list of its own, which is the one question a method object is
      # asked. A metaclass declines too — the methods of a singleton class's own
      # singleton class are a third object, which nothing asks for.
      def bound_method_object(receiver, argument_types, factory)
        return nil unless receiver.is_a?(AST::Types::Name::Singleton)

        method_name = literal_method_name(argument_types) or return nil
        object = AST::Types::MethodObject.new(
          type_name: receiver.name, method_name: method_name, singleton: true, unbound: false
        )

        object if method_definition(object, factory, public_only: false)
      end

      # `Method#parameters`, read off the method type the declaration states.
      #
      # Declined for a method with more than one overload: `parameters` answers
      # for the one implementation Ruby has, and a signature written as several
      # method types does not say which of them describes it.
      #
      # And declined unless every SUBCLASS answers the same list. A nominal type
      # names a class, and `singleton(::Sub)` is a `singleton(::Base)` — so the
      # class object this reflected on may be a subclass's, and an override with
      # a parameter list of its own is exactly the difference being asked about.
      # Reading the subclasses is what turns the declared class into the one the
      # value can be, and the closed world is what makes that readable.
      def parameters(receiver, argument_types, factory)
        return nil unless argument_types.empty?
        return nil unless receiver.is_a?(AST::Types::MethodObject)

        entries = parameter_entries_of(receiver, factory) or return nil

        descendants = factory.descendant_index.descendants(receiver.type_name, limit: MAX_DESCENDANTS)
        return nil unless descendants
        return nil unless descendants.all? do |name|
          parameter_entries_of(receiver.with(type_name: name), factory) == entries
        end

        AST::Types::Tuple.new(types: entries.map { |entry| entry_type(entry) })
      end

      # What one class's declaration of the method says its parameters are, or
      # nil where that is not one answer: no such method, more than one method
      # type, or a signature that states no parameter list at all.
      def parameter_entries_of(type, factory)
        method = method_definition(type, factory, public_only: false) or return nil
        return nil unless method.method_types.size == 1

        function = method.method_types.fetch(0).type
        return nil unless function.is_a?(RBS::Types::Function)

        parameter_entries(function)
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
        method: ::Kernel.instance_method(:singleton_class), handler: SINGLETON_CLASS
      ),
      "::Module#instance_method" => Entry.new(
        method: ::Module.instance_method(:instance_method), handler: INSTANCE_METHOD
      ),
      "::Module#public_instance_method" => Entry.new(
        method: ::Module.instance_method(:public_instance_method), handler: PUBLIC_INSTANCE_METHOD
      ),
      "::Kernel#method" => Entry.new(
        method: ::Kernel.instance_method(:method), handler: METHOD
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
