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
        return [receiver_type, constr] if reads?(constr.literal_method_registry, keys) && (!block || reading_block?(constr, block_params, block_body))
        if receiver&.type == :lvar || CollectionMutation.entered_with?(constr, receiver)
          return widened(constr, receiver, followed: !block && CollectionMutation.only?(constr, keys, WRITES))
        end

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

        ivar = held_ivar(constr, receiver, receiver_type)
        if CollectionMutation.only?(constr, keys, KEY_READ)
          read = read(constr, receiver_type, ivar, arguments) or return [type, constr]
          return [read, constr.add_typing(node, type: read).constr]
        end
        return [type, constr] unless ivar && CollectionMutation.only?(constr, keys, STORES)

        stored = stored(constr, receiver_type, arguments) || declared_hash(constr, ivar)
        [type, ObjectStates::ClassMemos.remembered_as(constr, receiver, ivar, stored)]
      end

      # The record a hash handed to `Klass.new` is, where `initialize` keeps it
      # in `ivar` and nothing but the object can change it: written at the
      # call, or held by a local nothing else names, and once stored only ever
      # changed the way `held?` follows.
      def held_record(constr, instance, ivar, argument, followed:)
        record =
          case argument.type
          when :hash then Specializations::Arguments.written_record(argument, constr.typing, nil)
          when :lvar then held_local_record(constr, argument)
          end
        record = record && storable(record)
        record if record && held?(constr, instance, ivar, record, followed: followed)
      end

      # What a hash a state follows may hold under a key: a value nothing can
      # change, or an object of a class, which stays of that class whatever is
      # done to it. A hash, an array or a string read out of it could be
      # changed through the name it was read into (`storable`).
      def record_value?(type)
        return type.types.all? { |member| record_value?(member) } if type.is_a?(AST::Types::Union)

        ObjectStates.fixed?(type) || [AST::Types::RegexpLiteral, AST::Types::Name::Singleton, AST::Types::Name::Instance].any? { |kind| type.is_a?(kind) }
      end

      # `record` as a state may hold it (`record_value?`), with a
      # hash, an array or a string under a key held as its class; nil where a
      # value is none of these.
      def storable(record)
        elements = record.elements.transform_values { |value| storable_value(value) or return nil }
        AST::Types::Record.new(elements: elements, required_keys: record.required_keys)
      end

      # Vouches for each local handed to a call that holds a record the checker
      # computed and follows: one nothing else names, in a body checked for
      # one call's arguments. A record a local is only declared to hold says
      # nothing of what the hash holds now (`Arguments.argument_type`).
      def vouch_held_records(constr, arguments)
        def_node = constr.method_context&.node
        return unless def_node && constr.specialization_arguments(def_node)

        arguments.each do |argument|
          next unless argument.type == :lvar

          record = held_local_record(constr, argument) and constr.typing.add_vouched(argument, record)
        end
      end

      # `followed`: the object is held by a local nothing else names, so each
      # call made through it moves its state, and a method of its own may also
      # write the hash by literal key (`autosave=`).
      def held?(constr, instance, ivar, record, followed:)
        record.is_a?(AST::Types::Record) && record.elements.each_value.all? { |value| record_value?(value) } &&
          only_changed_by?(constr, instance, ivar, followed ? [*READS, *WRITES] : READS)
      end

      # Whether no method of `instance` but `initialize` assigns `ivar` or lets
      # its hash out, every use its own methods make of the ivar is one of
      # `own_calls`, and every use the project makes of the readers that
      # answer it only reads the hash. A write from a body with a block may
      # land where the body's exit does not see it.
      def only_changed_by?(constr, instance, ivar, own_calls)
        registry = constr.constructor_bindings
        literal_methods = constr.literal_method_registry
        constr.checker.factory.definition_builder.build_instance(instance.name).ancestors.ancestors.each do |ancestor|
          registry.method_bodies(ancestor.name.to_s).each do |name, bodies|
            next if name == :initialize

            bodies.each do |body|
              return false unless body
              next if body.returns == ivar && registry.uses_of(name).all? { |use| reading_use?(constr, use) }
              return false if body.returns == ivar || body.handed.include?(ivar) || body.writes.include?(ivar)

              own = body.ivar_uses.fetch(ivar, [])
              return false unless own.all? { |use| use.kind != :yielded && use_within?(literal_methods, use, own_calls) }
              return false if body.exposes_self && !own.all? { |use| reading_use?(constr, use) }
            end
          end
        end
        true
      rescue RBS::BaseError
        false
      end

      def watched_keys
        @watched_keys ||= Set.new(ENTRIES.keys) | [EACH]
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end

      # Whether every use the project makes of `names`, a memo of a hash and
      # its ivar, only reads the hash or stores into it.
      def confined?(constructor_bindings, literal_methods, names)
        names.all? { |name| constructor_bindings.uses_of(name).all? { |use| confined_use?(literal_methods, use) } }
      end

      private

      def confined_use?(literal_methods, use)
        use_within?(literal_methods, use, [*READS, *STORES])
      end

      # What a block is handed out of a hash a state follows is a value nothing
      # can change the class of (`record_value?`).
      def reading_use?(constr, use)
        use.kind != :yielded && use_within?(constr.literal_method_registry, use, READS, elements: true)
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
        moved, answer =
          if CollectionMutation.only?(constr, keys, STORES)
            [stored(constr, record, arguments), nil]
          else
            deleted(constr, record, arguments)
          end
        constr = refined(constr, receiver, moved || unknown_contents(constr, receiver))
        answer ? [answer, constr.add_typing(node, type: answer).constr] : [type, constr]
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

      def stored(constr, record, arguments)
        key, value = CollectionMutation.operand_types(constr, arguments)
        value = value && storable_value(value)
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
