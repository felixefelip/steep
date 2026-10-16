module Steep
  # The contents of the hash a class keeps in a memo `@ivar ||= {}`
  # (`ObjectStates::ClassMemos.tracked_hash`), as a record of what was stored
  # under each literal key (felixefelip/rbs_infer#394):
  #
  #   def self.registry = @registry ||= {}
  #   registry[:wheel] = :round      # @registry: { wheel: :round }
  #   registry[:wheel]               # :round
  #
  # A read is dispatched against the record. A store is dispatched against the
  # hash the ivar declares and folded onto the record where its key is a
  # literal and its value one a state may hold. Any other call leaves the
  # contents unknown.
  module HashMutation
    READS = (
      %w[[] fetch key? has_key? include? member? dig size length empty? any? none? count keys values == eql? hash inspect to_s]
        .map { |name| "::Hash##{name}" } +
      %w[!~ class frozen? instance_of? is_a? itself kind_of? nil? object_id respond_to?].map { |name| "::Kernel##{name}" } +
      %w[! != equal? __id__].map { |name| "::BasicObject##{name}" }
    ).to_set.freeze

    STORES = Set["::Hash#[]=", "::Hash#store"].freeze

    class << self
      def widen_receiver(constr, receiver, receiver_type, method_name, private:, block_params:, block_body:)
        ivar = held_ivar(constr, receiver, receiver_type) or return [receiver_type, constr]

        keys = hash_method_keys(constr, method_name, private: private)
        block = block_params || block_body
        return [receiver_type, constr] if !block && only?(constr, keys, READS)

        declared = declared_hash(constr, ivar)
        return [declared, constr] if !block && only?(constr, keys, STORES)

        [declared, ObjectStates::ClassMemos.remembered_as(constr, receiver, ivar, declared)]
      end

      def fold_in_place(constr, node, receiver, receiver_type, method_name, arguments, type:, private:)
        ivar = held_ivar(constr, receiver, receiver_type) or return [type, constr]
        return [type, constr] unless only?(constr, hash_method_keys(constr, method_name, private: private), STORES)

        stored = stored(constr, receiver_type, arguments) || declared_hash(constr, ivar)
        [type, ObjectStates::ClassMemos.remembered_as(constr, receiver, ivar, stored)]
      end

      def confined_use?(constr, use)
        return false if use.kind == :escape || !use.element_calls.empty?

        names = [*READS, *STORES].select { |key| key.end_with?("##{use.called}") }
        !names.empty? && names.none? { |key| constr.literal_method_registry.blocked?(key) }
      end

      private

      def held_ivar(constr, receiver, receiver_type)
        return unless receiver_type.is_a?(AST::Types::Record) && ObjectStates.on_self?(receiver)

        ObjectStates::ClassMemos.tracked_hash(constr, ObjectStates.recorded_call(constr, receiver))
      end

      def stored(constr, record, arguments)
        key, value = arguments.map do |argument|
          return nil unless arguments.size == 2 && constr.typing.has_type?(argument)

          constr.literal_operand_type(argument, constr.typing.type_of(node: argument))
        end
        return unless key.is_a?(AST::Types::Literal) && key.value.is_a?(::Symbol) && value && ObjectStates.record_value?(value)

        AST::Types::Record.new(elements: record.elements.merge(key.value => value), required_keys: record.required_keys | [key.value])
      end

      def declared_hash(constr, ivar)
        declared = ObjectStates.declared_ivar(constr, ivar)
        declared.is_a?(AST::Types::Union) ? AST::Types::Union.build(types: declared.types.reject { |type| type.is_a?(AST::Types::Nil) }) : declared
      end

      def only?(constr, keys, allowed)
        !keys.empty? && keys.all? { |key| allowed.include?(key) && !constr.literal_method_registry.blocked?(key) }
      end

      def hash_method_keys(constr, method_name, private:)
        MethodIdentity.keys(constr, AST::Builtin::Hash.instance_type(AST::Builtin.any_type, AST::Builtin.any_type), method_name, private: private)
      end
    end
  end
end
