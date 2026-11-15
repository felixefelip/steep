module Steep
  module ObjectStates
    class << self
      # Whether nothing but the call it is the value of names `node`'s value:
      # held (`held_value?`), or the receiver of a call made on it.
      def unshared?(constr, node) = held_value?(constr, node) || constr.method_context&.value_uses&.receiver?(node) || false

      # Whether what the hashes an object `Klass.new` builds hold can be kept:
      # nothing but the call names it, and its `initialize` chain hands `self`
      # to nothing that could write them.
      def contents_kept?(constr, node, instance, chain, arguments_key)
        unshared?(constr, node) && KeptSelf.fresh_chain?(constr, instance, chain, arguments_key)
      end

      # `type` with what each hash its state holds forgotten: an object others
      # may name can have its hashes written through them.
      def without_contents(type)
        case type
        when AST::Types::ObjectState
          AST::Types::ObjectState.new(back_type: type.back_type, ivars: type.ivars.transform_values { |value| without_contents(value) })
        when AST::Types::Union then AST::Types::Union.build(types: type.types.map { |member| without_contents(member) })
        else type
        end
      end
    end
  end
end
