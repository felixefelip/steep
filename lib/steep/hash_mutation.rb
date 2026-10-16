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

    class << self
      def widen_receiver(constr, receiver, receiver_type, method_name, private:, block_params:, block_body:)
        ivar = held_ivar(constr, receiver, receiver_type) or return [receiver_type, constr]

        keys = hash_method_keys(constr, method_name, private: private)
        block = block_params || block_body
        return [receiver_type, constr] if !block && CollectionMutation.only?(constr, keys, READS)

        declared = declared_hash(constr, ivar)
        return [declared, constr] if !block && CollectionMutation.only?(constr, keys, STORES)

        [declared, ObjectStates::ClassMemos.remembered_as(constr, receiver, ivar, declared)]
      end

      def fold_in_place(constr, node, receiver, receiver_type, method_name, arguments, type:, private:)
        ivar = held_ivar(constr, receiver, receiver_type) or return [type, constr]

        keys = hash_method_keys(constr, method_name, private: private)
        if CollectionMutation.only?(constr, keys, KEY_READ)
          read = read(constr, receiver_type, ivar, arguments) or return [type, constr]
          return [read, constr.add_typing(node, type: read).constr]
        end
        return [type, constr] unless CollectionMutation.only?(constr, keys, STORES)

        stored = stored(constr, receiver_type, arguments) || declared_hash(constr, ivar)
        [type, ObjectStates::ClassMemos.remembered_as(constr, receiver, ivar, stored)]
      end

      # Whether every use the project makes of `names`, a memo of a hash and
      # its ivar, only reads the hash or stores into it.
      def confined?(constructor_bindings, literal_methods, names)
        names.all? { |name| constructor_bindings.uses_of(name).all? { |use| confined_use?(literal_methods, use) } }
      end

      private

      def confined_use?(literal_methods, use)
        return false if use.kind == :escape || !use.element_calls.empty?

        names = [*READS, *STORES].select { |key| key.end_with?("##{use.called}") }
        !names.empty? && names.none? { |key| literal_methods.blocked?(key) }
      end

      def held_ivar(constr, receiver, receiver_type)
        return unless receiver_type.is_a?(AST::Types::Record) && ObjectStates.on_self?(receiver)

        ObjectStates::ClassMemos.tracked_hash(constr, ObjectStates.recorded_call(constr, receiver))
      end

      # What `[]` answers where the record cannot: `nil` under a literal key it
      # does not hold, and the declared value under a key that is no literal.
      def read(constr, record, ivar, arguments)
        key, = CollectionMutation.operand_types(constr, arguments)
        return if literal_key?(key) && record.elements.key?(key.value)
        return AST::Builtin.nil_type if literal_key?(key)

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
