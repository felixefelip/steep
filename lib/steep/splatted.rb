module Steep
  # `*value`, as the values it spreads into where its type says how many. Ruby
  # asks the value for `to_a`, and spreads one that has none as itself.
  module Splatted
    # The tuple it spreads as, and whether that is the value itself rather than
    # its elements.
    def self.spread(constr, type)
      case type
      when AST::Types::Nil then [AST::Types::Tuple.new(types: []), true]
      when AST::Types::Literal, AST::Types::Name::Instance, AST::Types::ObjectState
        return [type, false] if AST::Builtin::Array.instance_type?(type) || constr.calculate_interface(type, :to_a, private: true)

        [AST::Types::Tuple.new(types: [type]), true]
      else [type, false]
      end
    end
  end
end
