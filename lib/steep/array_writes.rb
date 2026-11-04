module Steep
  # The writers of an array that answer it: `concat`, `push`, `<<`, … RBS
  # declares each `-> self` with what it is handed confined to `Elem`, which is
  # the array's type where a signature declared it. Where `Elem` is a value the
  # checker inferred for an array written out — a literal, an object with
  # state, `self` — the call adds elements that do not fit it:
  #
  #   [self].concat(parents)     # `Array[self]`, holding parents too
  #   [1, 2].concat(numbers)
  #
  # There each writer is generic over what it is handed, up to the class the
  # inferred element stands for, and answers an array of both.
  module ArrayWrites
    KEYS = %w[concat push append << unshift prepend insert].map { |name| "::Array##{name}" }.to_set.freeze

    class << self
      def entry(constr, entry, receiver_type)
        element = entry && element_type(receiver_type) or return entry
        erased = AST::Types::Union.build(types: members(element).map { |member| erased(constr, member) })
        return entry if erased == element

        Interface::Shape::Entry.new(
          method_name: entry.method_name, private_method: entry.private_method?,
          overloads: entry.overloads.map { |overload| writer?(constr, overload, entry.method_name) ? generic(overload, element, erased) : overload }
        )
      end

      private

      def element_type(receiver_type)
        case receiver_type
        when AST::Types::Tuple then AST::Types::Union.build(types: receiver_type.types) unless receiver_type.types.empty?
        else AST::Builtin::Array.instance_type?(receiver_type)&.args&.first
        end
      end

      def members(type) = type.is_a?(AST::Types::Union) ? type.types : [type]

      def erased(constr, member)
        case member
        when AST::Types::Literal, AST::Types::ObjectState then member.back_type
        when AST::Types::Self then constr.self_type.is_a?(AST::Types::Self) ? member : constr.self_type
        else member
        end
      end

      def writer?(constr, overload, method_name)
        keys = overload.method_decls(method_name).map { |decl| MethodIdentity.normalize(decl.method_name.to_s) }.uniq
        CollectionMutation.only?(constr, keys, KEYS)
      end

      def generic(overload, element, erased)
        method_type = overload.method_type
        added = AST::Types::Var.fresh(:Added)
        params = method_type.type.params&.map_type { |type| replaced(type, element, added) }
        param = Interface::TypeParam.new(name: added.name, upper_bound: erased, variance: :invariant, unchecked: false, default_type: nil)

        Interface::Shape::MethodOverload.new(
          method_type.with(
            type_params: [*method_type.type_params, param],
            type: method_type.type.with(params: params, return_type: AST::Builtin::Array.instance_type(AST::Types::Union.build(types: [element, added])))
          ),
          overload.method_defs
        )
      end

      def replaced(type, element, added)
        type == element ? added : type.map_type { |child| replaced(child, element, added) }
      end
    end
  end
end
