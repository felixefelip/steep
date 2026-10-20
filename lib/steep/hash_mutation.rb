module Steep
  # The contents of the hash a class keeps in a memo `@ivar ||= {}`
  # (`ObjectStates::ClassMemos.tracked_hash`), as a record of what was stored
  # under each literal key (felixefelip/rbs_infer#394):
  #
  #   def self.registry = @registry ||= {}
  #   registry[:wheel] = :round      # @registry: { wheel: :round }
  #   registry[:wheel]               # :round
  #   registry[:seat]                # nil
  #
  # A read is dispatched against the record. A store is dispatched against the
  # hash the ivar declares and folded onto the record where its key is a
  # literal and its value one a record may hold. Any other call leaves the
  # contents unknown.
  module HashMutation
    # What a value handed out holds is a value a record holds (`record_value?`),
    # and a call answering a new hash shares only those. `to_h` is not one: on
    # a `Hash` it answers the receiver.
    READS = (
      %w[
        [] key? has_key? include? member? size length empty? any? keys values == eql? hash inspect to_s
        fetch dig values_at fetch_values key to_a merge except slice compact select reject transform_values
      ].map { |name| "::Hash##{name}" } +
      %w[count none? all? find map filter_map].map { |name| "::Enumerable##{name}" } +
      CollectionMutation::OBJECT_READS
    ).to_set.freeze

    # What `Enumerable` runs to walk a hash.
    EACH = "::Hash#each"

    KEY_READ = Set["::Hash#[]"].freeze

    STORES = Set["::Hash#[]=", "::Hash#store"].freeze

    # What a local holding a record follows: a store, or `delete` of a key.
    WRITES = (STORES | ["::Hash#delete"]).freeze

    ENTRIES = (READS | WRITES).to_h { |key| [key, true] }.freeze

    class << self
      def widen_receiver(constr, receiver, receiver_type, method_name, private:, block_params:, block_body:)
        keys = hash_method_keys(constr, method_name, private: private)
        block = block_params || block_body
        receiver_type, constr = consumed(constr, receiver, receiver_type, keys, block: block) || [receiver_type, constr]
        return [receiver_type, constr] if reads?(constr.literal_method_registry, keys) && (!block || reading_block?(constr, block_params, block_body))
        if receiver&.type == :lvar || CollectionMutation.entered_with?(constr, receiver)
          return widened(constr, receiver, followed: !block && CollectionMutation.only?(constr, keys, WRITES))
        end
        if !block && CollectionMutation.only?(constr, keys, WRITES) && (state, ivar = read_off_state(constr, receiver))
          return [declared_on(constr, state.back_type, ivar), constr]
        end
        return [unknown_contents(constr, receiver), constr] if !block && CollectionMutation.only?(constr, keys, WRITES) && path(constr, receiver)

        ivar = held_ivar(constr, receiver, receiver_type) or return [receiver_type, constr]

        declared = declared_hash(constr, ivar)
        return [declared, constr] if !block && CollectionMutation.only?(constr, keys, STORES)

        [declared, ObjectStates::ClassMemos.remembered_as(constr, receiver, ivar, declared)]
      end

      def fold_in_place(constr, node, receiver, receiver_type, method_name, arguments, type:, private:)
        keys = hash_method_keys(constr, method_name, private: private)
        if (receiver&.type == :lvar || CollectionMutation.entered_with?(constr, receiver)) && CollectionMutation.only?(constr, keys, WRITES)
          return written(constr, node, receiver, receiver_type, keys, arguments, type: type)
        end
        if CollectionMutation.only?(constr, keys, WRITES) && (state, ivar = read_off_state(constr, receiver))
          return written_through(constr, node, receiver.children[0], state, ivar, receiver_type, keys, arguments, type: type)
        end
        if CollectionMutation.only?(constr, keys, WRITES) && receiver_type.is_a?(AST::Types::Record) && (along = path(constr, receiver))
          return written_along(constr, node, along, receiver_type, keys, arguments, type: type)
        end

        ivar = held_ivar(constr, receiver, receiver_type)
        if CollectionMutation.only?(constr, keys, KEY_READ)
          read = read(constr, receiver_type, ivar, arguments) or return read_by_key(constr, receiver, arguments, type)
          return [read, constr.add_typing(node, type: read).constr]
        end
        return [type, constr] unless ivar && CollectionMutation.only?(constr, keys, STORES)

        stored = stored(constr, receiver_type, arguments) || declared_hash(constr, ivar)
        [type, ObjectStates::ClassMemos.remembered_as(constr, receiver, ivar, stored)]
      end

      # The record a hash handed to `Klass.new` is, where `initialize` keeps it
      # in `ivar` and nothing but the object can change it: written at the
      # call, or held by a local nothing else names, and once stored only ever
      # changed the way `held` follows.
      def held_record(constr, instance, ivar, argument, followed:)
        record =
          case argument.type
          when :hash then Specializations::Arguments.written_record(argument, constr.typing, nil)
          when :lvar then held_local_record(constr, argument)
          end
        record = record && storable(record)
        record && held(constr, instance, ivar, record, followed: followed)
      end

      # What a hash a state follows may hold under a key: a value nothing can
      # change, an object of a class, which stays of that class whatever is
      # done to it, or `untyped`, which says nothing to change. A hash, an array or a string read out of it could be
      # changed through the name it was read into (`storable`).
      def record_value?(type)
        return type.types.all? { |member| record_value?(member) } if type.is_a?(AST::Types::Union)

        ObjectStates.fixed?(type) || [AST::Types::Any, AST::Types::RegexpLiteral, AST::Types::Name::Singleton, AST::Types::Name::Instance].any? { |kind| type.is_a?(kind) }
      end

      # `record` as a state may hold it (`record_value?`), with a
      # hash, an array or a string under a key held as its class; nil where a
      # value is none of these.
      def storable(record)
        elements = record.elements.transform_values { |value| storable_value(value) or return nil }
        AST::Types::Record.new(elements: elements, required_keys: record.required_keys)
      end

      # A hash written as the value of a local nothing else names, as the
      # record it is: every literal-key write made through the local moves it.
      def held_literal(constr, node, hint:)
        return unless node.type == :hash && hint.nil? && constr.method_context&.held_locals&.held_value?(node)

        record = Specializations::Arguments.written_record(node, constr.typing, nil)
        constr.add_typing(node, type: record) if record && ObjectStates.state_value?(record)
      end

      # Vouches for each local handed to a call that holds a record the checker
      # computed and follows (`followed_record`). A record a local is only
      # declared to hold says nothing of what the hash holds now
      # (`Arguments.argument_type`).
      def vouch_held_records(constr, arguments)
        arguments.each do |argument|
          record = followed_record(constr, argument) and constr.typing.add_vouched(argument, record)
        end
      end

      # What each local `vouch_held_records` vouched for holds once the call
      # returns: what the body the call ran left its parameter holding, where
      # it was checked under the record and its answer, which may be the
      # hash, is no record something here takes; the hash otherwise.
      def handed_back(constr, node, arguments)
        handed = handed_slots(constr, node, arguments).select { |_, argument| followed_record(constr, argument) }
        return constr if handed.empty?

        call = ObjectStates.recorded_call(constr, node)
        exits = ObjectStates.exit_of(constr, node, under: :hands_records?)&.params unless taken?(constr, node) && call && record_in?(call.return_type)
        handed.reduce(constr) do |current, (slot, argument)|
          ObjectStates.refine_local(current, argument.children[0], exits&.[](slot) || unknown_contents(current, argument))
        end
      end

      # What a body checked for one call's arguments leaves each parameter it
      # was handed a record in holding, by position or keyword: a parameter
      # nothing else in the body names, still holding a record.
      def param_exits(constr, def_node, arguments, env)
        held = constr.method_context&.held_locals or return {}
        positional, keyword = parameter_names(def_node)
        slots = arguments.positionals.each_with_index.map { |type, index| [index, positional[index], type] } +
                arguments.keywords.map { |name, type| [name, (name if keyword.include?(name)), type] }
        slots.each_with_object({}) do |(slot, name, arrived), exits|
          next unless name && arrived.is_a?(AST::Types::Record) && held.held?(name)

          left = env[name]
          exits[slot] = left if left.is_a?(AST::Types::Record)
        end
      end

      # The record `ivar` holds for an object built with `record` there, where
      # nothing but a literal-key write can change it: held by a local nothing
      # else names (`followed`), `record`, since each write made through it
      # moves its state; under any name, `record` with whatever every such
      # write the project makes may have left (`widened_by`).
      def held(constr, instance, ivar, record, followed:)
        return unless record.is_a?(AST::Types::Record) && record.elements.each_value.all? { |value| record_value?(value) }

        writes = writes_to(constr, instance, ivar) or return
        return record if followed

        value = declared_value(constr, instance, ivar)
        writes.reduce(record) { |held, use| widened_by(held, use, value) or return }
      end

      # The writes made to `ivar`'s hash, by the methods of `instance` and on
      # what the readers that answer it do, where no method of `instance` but
      # `initialize` assigns `ivar` or lets its hash out, and every other use
      # of either only reads the hash. Nil otherwise.
      def writes_to(constr, instance, ivar)
        registry = constr.constructor_bindings
        writes = [] #: Array[TypeInference::ClassMemoAnalyzer::Use]
        constr.checker.factory.definition_builder.build_instance(instance.name).ancestors.ancestors.each do |ancestor|
          registry.method_bodies(ancestor.name.to_s).each do |name, bodies|
            next if name == :initialize

            bodies.each do |body|
              made = body_writes(constr, instance, ivar, name, body) or return
              writes.concat(made)
            end
          end
        end
        writes
      rescue RBS::BaseError
        nil
      end

      def body_writes(constr, instance, ivar, name, body)
        return unless body
        if body.returns == ivar
          return reader_writes(constr, Specializations::Receivers.uses_on(constr, name, instance), name)
        end
        return if body.handed.include?(ivar) || body.writes.include?(ivar)

        literal_methods = constr.literal_method_registry
        own = body.ivar_uses.fetch(ivar, [])
        return unless own.all? { |use| use.kind != :yielded && use_within?(literal_methods, use, [*READS, *WRITES]) }
        return if body.exposes_self && !own.all? { |use| reading_use?(constr, use) }

        own.select { |use| use_within?(literal_methods, use, WRITES) }
      end

      def watched_keys
        @watched_keys ||= Set.new(ENTRIES.keys) | [EACH]
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end

      # Whether each of `uses`, of a memo of a hash and of its ivar, only
      # reads the hash or stores into it.
      def confined?(literal_methods, uses)
        uses.all? { |use| confined_use?(literal_methods, use) }
      end

      private

      def confined_use?(literal_methods, use)
        use_within?(literal_methods, use, [*READS, *STORES])
      end

      # What a block is handed out of a hash a state follows is a value nothing
      # can change the class of (`record_value?`).
      def reading_use?(constr, use, forwarders = Set[])
        return reading_uses?(constr, constr.constructor_bindings.uses_of(use.forwarded_by), use.forwarded_by, forwarders) if use.forwarded_by

        use.kind != :yielded && use_within?(constr.literal_method_registry, use, READS, elements: true)
      end

      # The writes made on what a reader answers, where every other use of it
      # only reads the hash: on the local that holds the object, or an ivar the
      # body holds, `written_through` moves its state, and on any other object
      # they are among what `held` widens it by.
      def reader_writes(constr, uses, name)
        writes = uses.select { |use| use.at && use.direct && use_within?(constr.literal_method_registry, use, WRITES) }
        writes if reading_uses?(constr, uses - writes, name)
      end

      # `record` where the write `use` may or may not have run: the key it
      # names holding what it held or `value`, or no longer required where it
      # deletes it. Nil for a write by any other key.
      def widened_by(record, use, value)
        key = use.key or return
        current = record.elements[key]
        return AST::Types::Record.new(elements: record.elements, required_keys: record.required_keys - [key]) if use.called == :delete

        element = current ? AST::Types::Union.build(types: [current, value]) : value
        AST::Types::Record.new(elements: record.elements.merge(key => element), required_keys: record.required_keys)
      end

      def declared_value(constr, instance, ivar)
        declared = declared_on(constr, instance, ivar)
        hash = declared.is_a?(AST::Types::Name::Instance) && declared.name == AST::Builtin::Hash.module_name
        (hash && declared.args[1]) || AST::Builtin.any_type
      end

      # A method that answers what a reader does is a reader too, whatever
      # class it is on. One already being checked has its other uses checked
      # there.
      def reading_uses?(constr, uses, name, forwarders = Set[])
        return true if forwarders.include?(name)

        uses.all? { |use| reading_use?(constr, use, forwarders | [name]) }
      end

      def use_within?(literal_methods, use, allowed, elements: false)
        return false if use.kind == :escape || (!elements && !use.element_calls.empty?)

        names = allowed.select { |key| key.end_with?("##{use.called}") }
        !names.empty? && names.none? { |key| blocked?(literal_methods, key) }
      end

      def reads?(literal_methods, keys)
        !keys.empty? && keys.all? { |key| READS.include?(key) && !blocked?(literal_methods, key) }
      end

      def blocked?(literal_methods, key)
        literal_methods.blocked?(key) || (key.start_with?("::Enumerable#") && literal_methods.blocked?(EACH))
      end

      def reading_block?(constr, block_params, block_body)
        calls = TypeInference::ClassMemoAnalyzer.element_calls_in(block_params, block_body) or return false
        ObjectStates::ClassMemos.reads_elements?(constr, calls)
      end

      # A call on a local, or an ivar the body was entered with, holding a
      # record, dispatched against a hash: one `written` follows leaves the
      # variable for it to move; any other leaves it the hash.
      def widened(constr, receiver, followed:)
        hash = unknown_contents(constr, receiver)
        [hash, followed ? constr : refined(constr, receiver, hash)]
      end

      # A literal-key write on a variable holding a record moves the record;
      # the call answers what `delete` removed, `nil` for a key the record did
      # not hold. Any other write leaves the variable the hash.
      def written(constr, node, receiver, record, keys, arguments, type:)
        moved, answer = moved(constr, record, keys, arguments, fresh: left?(constr, node) && (receiver.type == :ivar || followed_local?(constr, receiver.children[0])))
        constr = refined(constr, receiver, moved || unknown_contents(constr, receiver))
        answer ? [answer, constr.add_typing(node, type: answer).constr] : [type, constr]
      end

      # `written` on the hash an object holds, read through its reader: a
      # write made off a local nothing else names moves the object's state, and
      # one made off any other variable, or one `written` does not follow,
      # leaves the ivar out of what it holds.
      def written_through(constr, node, object, state, ivar, record, keys, arguments, type:)
        followed = followed?(constr, object)
        moved, answer = moved(constr, record, keys, arguments, fresh: followed && left?(constr, node))
        constr = left_holding(constr, object, state, ivar, (moved if followed))
        answer ? [answer, constr.add_typing(node, type: answer).constr] : [type, constr]
      end

      def moved(constr, record, keys, arguments, fresh:)
        return [stored(constr, record, arguments, fresh: fresh), (fresh_record(constr, arguments[1]) if fresh)] if CollectionMutation.only?(constr, keys, STORES)

        deleted(constr, record, arguments)
      end

      def followed?(constr, object)
        return constr.method_context&.held_locals&.held?(object.children[0]) || false if object.type == :lvar

        holder = ObjectStates::HeldIvar.self_ivar(constr, object)
        !holder.nil? && ObjectStates::HeldIvar.held?(constr, holder)
      end

      # `constr` with the variable `object` reads, a local or an ivar of
      # `self`, holding `state` with `record` in `ivar`, or without `ivar`
      # where `record` is nil.
      def left_holding(constr, object, state, ivar, record)
        name = ObjectStates::HeldIvar.variable(constr, object) or return constr

        ivars = record ? state.ivars.merge(ivar => record) : state.ivars.except(ivar)
        left = ivars.empty? ? state.back_type : AST::Types::ObjectState.new(back_type: state.back_type, ivars: ivars)
        current = constr.context.type_env[name]
        left = AST::Types::Intersection.build(types: current.types.map { |member| member == state ? left : member }) if current.is_a?(AST::Types::Intersection)
        ObjectStates::HeldIvar.refine_variable(constr, object, left)
      end

      # `[state, ivar]` where `receiver` calls, with no arguments, the reader
      # of `ivar` on an object whose state holds a record there.
      def read_off_state(constr, receiver)
        return unless receiver && Specializations::Receivers::SENDS.include?(receiver.type) && receiver.children.size == 2

        object = receiver.children[0]
        return unless object && constr.typing.has_type?(object)

        state = ObjectStates.state_in(constr.typing.type_of(node: object)) or return
        call = ObjectStates.recorded_call(constr, receiver)
        ivar = call.is_a?(TypeInference::MethodCall::Typed) && ObjectStates.reader_ivar(constr, state, call)
        [state, ivar] if ivar && state.ivar_type(ivar).is_a?(AST::Types::Record)
      end

      def declared_on(constr, instance, ivar)
        declared = constr.checker.factory.definition_builder.build_instance(instance.name).instance_variables[ivar]
        declared ? constr.checker.factory.type(declared.type) : AST::Builtin::Hash.instance_type(AST::Builtin.any_type, AST::Builtin.any_type)
      end

      def unknown_contents(constr, receiver)
        return declared_hash(constr, receiver.children[0]) if receiver.type == :ivar

        AST::Builtin::Hash.instance_type(AST::Builtin.any_type, AST::Builtin.any_type)
      end

      def refined(constr, receiver, type)
        name = receiver.children[0] #: Symbol
        return ObjectStates.refine_local(constr, name, type) if receiver.type == :lvar

        constr.update_type_env { |env| env.refine_types(instance_variable_types: { name => type }) }
      end

      def deleted(constr, record, arguments)
        key, = CollectionMutation.operand_types(constr, arguments)
        return [nil, nil] unless arguments.size == 1 && literal_key?(key)

        elements = record.elements.except(key.value)
        answer = record.elements.fetch(key.value) { AST::Builtin.nil_type }
        answer = AST::Types::Union.build(types: [answer, AST::Builtin.nil_type]) unless record.required_keys.include?(key.value) || answer.is_a?(AST::Types::Nil)
        [AST::Types::Record.new(elements: elements, required_keys: record.required_keys - [key.value]), answer]
      end

      def held_local_record(constr, node)
        return unless constr.method_context&.held_locals&.held?(node.children[0])

        type = constr.typing.type_of(node: node)
        type if type.is_a?(AST::Types::Record)
      end

      # The record a local nothing else names holds, where the checker
      # computed it: written as a hash here, or in a body checked for one
      # call's arguments.
      def followed_record(constr, node)
        held_local_record(constr, node) if node.type == :lvar && followed_local?(constr, node.children[0])
      end

      def followed_local?(constr, name)
        def_node = constr.method_context&.node or return false
        held = constr.method_context.held_locals
        held.held?(name) && (!constr.specialization_arguments(def_node).nil? || held.written_hash?(name))
      end

      # Each argument node with the slot it fills: its position among the
      # positionals, or its keyword.
      def handed_slots(constr, node, arguments)
        arguments = arguments.dup
        keywords = arguments.last&.type == :kwargs ? arguments.pop.children : []
        arguments = arguments.drop(1) if TypeConstruction::SEND_SPELLINGS.key?(node.children[1]) && Specializations::Arguments.dispatched?(node, constr.typing)
        slots = arguments.each_with_index.map { |argument, index| [index, argument] }
        slots + keywords.filter_map { |pair| [pair.children[0].children[0], pair.children[1]] if pair.type == :pair && pair.children[0].type == :sym }
      end

      def parameter_names(def_node)
        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        params = args.children.select { |param| param.is_a?(::Parser::AST::Node) }
        positional = params.take_while { |param| %i[arg optarg].include?(param.type) }.map { |param| param.children[0] }
        keyword = params.select { |param| %i[kwarg kwoptarg].include?(param.type) }.map { |param| param.children[0] }
        [positional, keyword]
      end

      def held_ivar(constr, receiver, receiver_type)
        return unless receiver_type.is_a?(AST::Types::Record) && ObjectStates.on_self?(receiver)

        ObjectStates::ClassMemos.tracked_hash(constr, ObjectStates.recorded_call(constr, receiver))
      end

      # What `[]` answers where the record cannot: `nil` under a literal key it
      # does not hold, on any record, and, on a memo's, the declared value under
      # a key that is no literal.
      def read(constr, record, ivar, arguments)
        key, = CollectionMutation.operand_types(constr, arguments)
        if arguments.size == 1 && key.is_a?(AST::Types::Literal)
          return record.elements.key?(key.value) ? nil : AST::Builtin.nil_type
        end
        return unless ivar

        declared = declared_hash(constr, ivar)
        declared.args[1] if declared.is_a?(AST::Types::Name::Instance) && declared.args.size == 2
      end

      def stored(constr, record, arguments, fresh: false)
        key, value = CollectionMutation.operand_types(constr, arguments)
        value = (fresh && fresh_record(constr, arguments[1])) || (value && storable_value(value))
        return unless arguments.size == 2 && literal_key?(key) && value

        AST::Types::Record.new(elements: record.elements.merge(key.value => value), required_keys: record.required_keys | [key.value])
      end

      def storable_value(type)
        return type if record_value?(type)

        case type
        when AST::Types::Record then AST::Builtin::Hash.instance_type(AST::Builtin.any_type, AST::Builtin.any_type)
        when AST::Types::Tuple then AST::Builtin::Array.instance_type(AST::Builtin.any_type)
        when AST::Types::Literal then AST::Builtin::String.instance_type if type.value.is_a?(::String)
        when AST::Types::Union
          AST::Types::Union.build(types: type.types.map { |member| storable_value(member) or return nil })
        end
      end

      def literal_key?(type)
        type.is_a?(AST::Types::Literal) && type.value.is_a?(::Symbol)
      end

      def declared_hash(constr, ivar)
        declared = ObjectStates.declared_ivar(constr, ivar)
        declared.is_a?(AST::Types::Union) ? AST::Types::Union.build(types: declared.types.reject { |type| type.is_a?(AST::Types::Nil) }) : declared
      end

      def hash_method_keys(constr, method_name, private:)
        MethodIdentity.keys(constr, AST::Builtin::Hash.instance_type(AST::Builtin.any_type, AST::Builtin.any_type), method_name, private: private)
      end
    end
  end
end
