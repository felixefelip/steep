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
    READS = (
      %w[[] key? has_key? include? member? size length empty? any? none? count keys values == eql? hash inspect to_s]
        .map { |name| "::Hash##{name}" } + CollectionMutation::OBJECT_READS
    ).to_set.freeze

    KEY_READ = Set["::Hash#[]"].freeze

    STORES = Set["::Hash#[]=", "::Hash#store"].freeze

    # What a local holding a record follows: a store, or `delete` of a key.
    WRITES = (STORES | ["::Hash#delete"]).freeze

    class << self
      def widen_receiver(constr, receiver, receiver_type, method_name, private:, block_params:, block_body:)
        keys = hash_method_keys(constr, method_name, private: private)
        block = block_params || block_body
        return [receiver_type, constr] if !block && CollectionMutation.only?(constr, keys, READS)
        return local_widened(constr, receiver, followed: !block && CollectionMutation.only?(constr, keys, WRITES)) if receiver&.type == :lvar

        ivar = held_ivar(constr, receiver, receiver_type) or return [receiver_type, constr]

        declared = declared_hash(constr, ivar)
        return [declared, constr] if !block && CollectionMutation.only?(constr, keys, STORES)

        [declared, ObjectStates::ClassMemos.remembered_as(constr, receiver, ivar, declared)]
      end

      def fold_in_place(constr, node, receiver, receiver_type, method_name, arguments, type:, private:)
        keys = hash_method_keys(constr, method_name, private: private)
        if receiver&.type == :lvar && CollectionMutation.only?(constr, keys, WRITES)
          return local_written(constr, node, receiver, receiver_type, keys, arguments, type: type)
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
      # call, or held by a local nothing else names, and only ever read once
      # stored (`read_only?`).
      def held_record(constr, instance, ivar, argument)
        record =
          case argument.type
          when :hash then Specializations::Arguments.written_record(argument, constr.typing, nil)
          when :lvar then held_local_record(constr, argument)
          end
        record if record && held?(constr, instance, ivar, record)
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

      def held?(constr, instance, ivar, record)
        record.is_a?(AST::Types::Record) && record.elements.each_value.all? { |value| ObjectStates.record_value?(value) } &&
          read_only?(constr, instance, ivar)
      end

      # Whether no method of `instance` but `initialize` writes `ivar` or lets
      # its hash out, and every use the project makes of it and of the
      # readers that answer it only reads the hash.
      def read_only?(constr, instance, ivar)
        registry = constr.constructor_bindings
        uses = [] #: Array[TypeInference::ClassMemoAnalyzer::Use]
        constr.checker.factory.definition_builder.build_instance(instance.name).ancestors.ancestors.each do |ancestor|
          registry.method_bodies(ancestor.name.to_s).each do |name, bodies|
            next if name == :initialize

            bodies.each do |body|
              return false unless body
              next uses.concat(registry.uses_of(name)) if body.returns == ivar
              return false if body.handed.include?(ivar) || body.writes.include?(ivar)

              uses.concat(body.ivar_uses.fetch(ivar, []))
            end
          end
        end
        uses.all? { |use| reading_use?(constr.literal_method_registry, use) }
      rescue RBS::BaseError
        false
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

      def reading_use?(literal_methods, use)
        use.kind != :yielded && use_within?(literal_methods, use, READS)
      end

      def use_within?(literal_methods, use, allowed)
        return false if use.kind == :escape || !use.element_calls.empty?

        names = allowed.select { |key| key.end_with?("##{use.called}") }
        !names.empty? && names.none? { |key| literal_methods.blocked?(key) }
      end

      # A call on a local holding a record, dispatched against a plain hash:
      # one `local_written` follows leaves the local for it to move; any other
      # leaves it the hash.
      def local_widened(constr, receiver, followed:)
        hash = AST::Builtin::Hash.instance_type(AST::Builtin.any_type, AST::Builtin.any_type)
        [hash, followed ? constr : ObjectStates.refine_local(constr, receiver.children[0], hash)]
      end

      # A literal-key write on a local holding a record moves the record; the
      # call answers what `delete` removed, `nil` for a key the record did not
      # hold. Any other write leaves the local the hash.
      def local_written(constr, node, receiver, record, keys, arguments, type:)
        moved, answer =
          if CollectionMutation.only?(constr, keys, STORES)
            [stored(constr, record, arguments), nil]
          else
            deleted(constr, record, arguments)
          end
        hash = AST::Builtin::Hash.instance_type(AST::Builtin.any_type, AST::Builtin.any_type)
        constr = ObjectStates.refine_local(constr, receiver.children[0], moved || hash)
        answer ? [answer, constr.add_typing(node, type: answer).constr] : [type, constr]
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
        return unless arguments.size == 2 && literal_key?(key) && value && ObjectStates.record_value?(value)

        AST::Types::Record.new(elements: record.elements.merge(key.value => value), required_keys: record.required_keys | [key.value])
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
