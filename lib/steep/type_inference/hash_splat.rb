module Steep
  module TypeInference
    # The key and value types a `**value` adds to the hash it is splatted
    # into, or nil when its type says nothing about them. A record adds its
    # keys as literals; an empty one adds nothing, `bot`.
    module HashSplat
      def self.key_value(type)
        case
        when AST::Builtin::Hash.instance_type?(type)
          # @type var type: AST::Types::Name::Instance
          [type.args.fetch(0), type.args.fetch(1)]
        when type.is_a?(AST::Types::Record)
          keys = type.elements.keys.map { AST::Types::Literal.new(value: _1) }
          [AST::Types::Union.build(types: keys), AST::Types::Union.build(types: type.elements.values)]
        end
      end
    end
  end
end
