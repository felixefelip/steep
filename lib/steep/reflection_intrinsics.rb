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
  # Where that stops: a name written into a class from inside a string eval, and
  # a module mixed in without the signatures recording it. Neither the ancestry
  # nor the registry can see those — the same boundary `LiteralMethodRegistry`
  # already draws. Writing a string eval is not itself disqualifying, and must
  # not be: a macro that evals into its own class is what this reads for.
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

    KERNEL = RBS::TypeName.parse("::Kernel")
    NIL_CLASS = RBS::TypeName.parse("::NilClass")

    class << self
      def fold(call:, receiver_type:, argument_types:, factory:, override_registry:)
        key = MethodIdentity.key(call) or return nil
        entry = ENTRIES[key] or return nil
        return nil if override_registry.blocked?(key)
        return nil if shadowed?(receiver_type, key, entry, factory, override_registry)
        source_location = entry.method.source_location
        return nil if source_location && !source_location.first.start_with?("<internal:")

        entry.handler.call(receiver_type, argument_types, factory, override_registry)
      rescue StandardError => exn
        # Reflection is optional, so a bug here must not take down type
        # checking — but it must be visible.
        Steep.logger.warn do
          "[reflection_intrinsics] unexpected failure for #{key || "(unresolved)"}: #{exn.class}: #{exn.message}"
        end
        Steep.logger.debug { exn.full_message(highlight: false) }
        nil
      end

      # Whether this reflection is one Ruby answers by RAISING: `NameError`,
      # for a method the module does not have. The other half of `fold`, and
      # asked only where the program rescues it (`TypeConstruction`'s
      # `:rescue`) — which is where `ActiveSupport::Delegation.generate` falls
      # back to `"..."`:
      #
      #   module Labels
      #     delegate :human_name, to: :class   # Labels.singleton_class has none
      #     class_methods do                   # …it is ClassMethods', the host's
      #       def human_name(index) = index
      #     end
      #   end
      #
      # Absent from the receiver AND every descendant: a `singleton(X)` may be
      # a subclass's class object, and one that declares the method answers
      # it. A module this cannot build is a question, not an absence.
      def raises_name_error?(call:, receiver_type:, argument_types:, factory:, override_registry:)
        key = MethodIdentity.key(call) or return false
        public_only = RAISING_KEYS[key]
        return false if public_only.nil?

        entry = ENTRIES.fetch(key)
        return false if override_registry.blocked?(key)
        return false if shadowed?(receiver_type, key, entry, factory, override_registry)

        type_name, singleton = reflected_target(receiver_type)
        return false unless type_name

        method_name = literal_method_name(argument_types) or return false
        object = AST::Types::MethodObject.new(
          type_name: type_name, method_name: method_name, singleton: singleton, unbound: true
        )
        subjects = across_descendants(object, factory) or return false

        [object, *subjects].all? { |subject| declares?(subject, factory, public_only: public_only) == false }
      rescue StandardError => exn
        Steep.logger.warn { "[reflection_intrinsics] unexpected failure in raises_name_error?: #{exn.class}: #{exn.message}" }
        false
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
        @dispatched_names ||= Set.new(ENTRIES.each_value.map { |entry| entry.method.name }) + CONSULTED_NAMES
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
        # A redefinition whose owner could not be read at all — `def
        # obj.method(name)`. There is no chain to place it on, so it counts
        # against every receiver.
        return true if override_registry.name_blocked?(entry.method.name)

        # A value of a union is a value of one of its members, and Ruby looks
        # the method up on whichever it turns out to be.
        if receiver_type.is_a?(AST::Types::Union)
          return receiver_type.types.any? { |type| shadowed?(type, key, entry, factory, override_registry) }
        end

        chain = dispatch_chain(receiver_type, entry.method.name, factory) or return true
        overridden_before?(chain, key, override_registry)
      end

      # Whether the project redefines the method somewhere on `chain` before
      # Ruby reaches `key`, the core declaration. A chain that never reaches
      # it is one whose implementation is not the core's.
      def overridden_before?(chain, key, override_registry)
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
          else
            name = instance_class_name(receiver_type, factory)
            builder.instance_ancestors(name) if name
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

      # `true`/`false` for whether the declaration has the method (publicly,
      # where asked), or nil when the module cannot be built at all.
      def declares?(type, factory, public_only:)
        builder = factory.definition_builder
        definition = type.singleton ? builder.build_singleton(type.type_name) : builder.build_instance(type.type_name)
        method = definition.methods[type.method_name] or return false

        public_only ? method.public? : true
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

      # The class a value of `type` is an instance of, where the type names one
      # class rather than one of several: `nil` is a `NilClass`, `:a` a
      # `Symbol`, `::Post` a `Post` — or an instance of a subclass of it, which
      # is the caller's to ask about. A module is not a class a value is an
      # instance of, so its name is not one.
      def instance_class_name(type, factory)
        name =
          case type
          when AST::Types::Name::Instance then type.name
          when AST::Types::Nil then NIL_CLASS
          when AST::Types::Literal
            case type.value
            when true then RBS::BuiltinNames::TrueClass.name
            when false then RBS::BuiltinNames::FalseClass.name
            when ::Symbol then RBS::BuiltinNames::Symbol.name
            when ::String then RBS::BuiltinNames::String.name
            when ::Integer then RBS::BuiltinNames::Integer.name
            end
          end
        return nil unless name

        name if factory.env.class_decls[name].is_a?(RBS::Environment::ClassEntry)
      end

      # `Kernel#respond_to?(name)`: whether every class the receiver may be
      # an instance of — or, for `singleton(::C)`, every class object it may be
      # — gives the same answer, and which.
      #
      # `true` where each of them declares the method publicly. `false` where
      # none of them has it at all, nor reaches a `respond_to_missing?` other
      # than the core's — the one that answers false — since a method missing
      # from the signatures is one Ruby still finds there. A `respond_to?` the
      # project writes for itself answers whatever it says, so it declines the
      # whole question. Anything between declines too: a receiver one subclass
      # of which declares the method and another does not has no answer this
      # can give.
      #
      # This is how `ActiveSupport::Delegation` writes `allow_nil: true`:
      #
      #   _ = owner
      #   if !_.nil? || nil.respond_to?(:full_name)
      #     _.full_name(...)
      #   end
      #
      # NilClass has no `full_name`, so the condition is `!_.nil?` and `_` is
      # narrowed in the body the way any other guard narrows it.
      def responds_to(receiver, argument_types, factory, override_registry)
        method_name = literal_method_name(argument_types) or return nil
        subjects = respondents(receiver, factory) or return nil

        answers = subjects.map { |subject| responds?(subject, method_name, factory, override_registry) }
        return nil if answers.include?(nil) || answers.uniq.size != 1

        AST::Types::Literal.new(value: answers.first)
      end

      # Every class (as `[name, singleton]`) a value of `type` may be an
      # instance — or the class object — of, subclasses included. nil where
      # that is not a finite list of classes.
      def respondents(type, factory)
        case type
        when AST::Types::Union
          members = type.types.map { |member| respondents(member, factory) }
          members.all? ? members.flatten(1).uniq : nil
        when AST::Types::Boolean
          respondents(AST::Types::Union.build(types: [AST::Types::Literal.new(value: true), AST::Types::Literal.new(value: false)]), factory)
        when AST::Types::Name::Singleton
          with_descendants(type.name, true, factory)
        else
          name = instance_class_name(type, factory) or return nil
          with_descendants(name, false, factory)
        end
      end

      def with_descendants(name, singleton, factory)
        descendants = factory.descendant_index.descendants(name, limit: MAX_DESCENDANTS) or return nil

        [name, *descendants].map { |descendant| [descendant, singleton] }
      end

      # One class's answer, or nil where it is not the core's to give.
      def responds?(subject, method_name, factory, override_registry)
        type_name, singleton = subject
        builder = factory.definition_builder
        definition = singleton ? builder.build_singleton(type_name) : builder.build_instance(type_name)
        ancestors =
          singleton ? builder.ancestor_builder.singleton_ancestors(type_name) : builder.ancestor_builder.instance_ancestors(type_name)

        return nil unless core?(definition, ancestors, :respond_to?, override_registry)

        method = definition.methods[method_name]
        return true if method&.public?
        return false if core?(definition, ancestors, :respond_to_missing?, override_registry)

        nil
      rescue RBS::BaseError
        nil
      end

      # Whether `method_name` is, for this class, Kernel's: declared there and
      # not redefined in Ruby anywhere before it on the lookup chain.
      def core?(definition, ancestors, method_name, override_registry)
        method = definition.methods[method_name] or return false
        return false unless method.defined_in == KERNEL
        return false if override_registry.name_blocked?(method_name)

        chain = ancestors.ancestors.map do |ancestor|
          separator = ancestor.is_a?(RBS::Definition::Ancestor::Singleton) ? "." : "#"
          "::#{ancestor.name.to_s.delete_prefix("::")}#{separator}#{method_name}"
        end
        !overridden_before?(chain, "::Kernel##{method_name}", override_registry)
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

        return nil unless method_definition(object, factory, public_only: public_only)

        if public_only
          # `public_instance_method` RAISES on a private method, and the class
          # this ran on may be a subclass's: one that redeclares the method
          # private answers `NameError` where this would answer a method
          # object. Settled here, where Ruby would raise, rather than at the
          # question asked of the result.
          subjects = across_descendants(object, factory) or return nil
          return nil unless subjects.all? { |subject| method_definition(subject, factory, public_only: true) }
        end

        object
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

        subjects = across_descendants(receiver, factory) or return nil
        return nil unless subjects.all? { |subject| parameter_entries_of(subject, factory) == entries }

        AST::Types::Tuple.new(types: entries.map { |entry| entry_type(entry) })
      end

      # The same method object, once per class the receiver could actually have
      # been — every subclass of the one it names. nil where there are more of
      # them than `MAX_DESCENDANTS`, which declines whatever was being asked.
      def across_descendants(object, factory)
        descendants = factory.descendant_index.descendants(object.type_name, limit: MAX_DESCENDANTS)
        return nil unless descendants

        descendants.map { |name| object.with(type_name: name) }
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

    SINGLETON_CLASS = lambda do |receiver, argument_types, _factory, _override_registry|
      next nil unless argument_types.empty?
      next nil unless receiver.is_a?(AST::Types::Name::Singleton)

      AST::Types::MetaClass.new(name: receiver.name)
    end
    INSTANCE_METHOD = lambda do |receiver, argument_types, factory, _override_registry|
      unbound_method_object(receiver, argument_types, factory, public_only: false)
    end
    PUBLIC_INSTANCE_METHOD = lambda do |receiver, argument_types, factory, _override_registry|
      unbound_method_object(receiver, argument_types, factory, public_only: true)
    end
    METHOD = lambda do |receiver, argument_types, factory, _override_registry|
      bound_method_object(receiver, argument_types, factory)
    end
    PARAMETERS = lambda do |receiver, argument_types, factory, _override_registry|
      parameters(receiver, argument_types, factory)
    end
    # The name a module named exactly is reached by: `Store.name` is
    # `"Store"`. `ActiveSupport::Delegation` writes it into the receiver of a
    # method delegated `to:` a module — `"::#{to.name}"`. A `def self.name`
    # the project writes anywhere on the receiver's chain shadows it, as for
    # every entry here.
    NAME = lambda do |receiver, argument_types, _factory, _override_registry|
      next nil unless argument_types.empty?
      next nil unless receiver.is_a?(AST::Types::Name::Singleton)

      AST::Types::Literal.new(value: receiver.name.to_s.delete_prefix("::"))
    end

    RESPOND_TO = lambda do |receiver, argument_types, factory, override_registry|
      responds_to(receiver, argument_types, factory, override_registry)
    end

    # Names a reflection does not dispatch under but CONSULTS, so that a
    # redefinition of one changes its answer: `respond_to?` asks
    # `respond_to_missing?` for a method it does not find.
    CONSULTED_NAMES = %i[respond_to_missing?].freeze

    # The reflections that raise `NameError` for a missing method, with whether
    # a private one counts as missing.
    RAISING_KEYS = {
      "::Module#instance_method" => false,
      "::Module#public_instance_method" => true
    }.freeze

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
      ),
      "::Module#name" => Entry.new(
        method: ::Module.instance_method(:name), handler: NAME
      ),
      "::Kernel#respond_to?" => Entry.new(
        method: ::Kernel.instance_method(:respond_to?), handler: RESPOND_TO
      )
    }.freeze
  end
end
