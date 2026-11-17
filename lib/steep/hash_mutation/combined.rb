module Steep
  # `except` and `merge` on a record answer a new hash, and so does `merge!`
  # on a hash only one of those just built, which nothing else names:
  #
  #   reflections.except(name).merge!(name => reflection)   # { comments: Reflection }
  #
  # A key is a literal symbol, written out or carried by a variable, and a
  # merged hash is one written at the call.
  module HashMutation
    COMBINES = Set["::Hash#except", "::Hash#merge", "::Hash#merge!"].freeze

    class << self
      def combined(constr, node, receiver, record, keys, arguments)
        return unless node.type == :send && record.is_a?(AST::Types::Record) && keys.size == 1 && CollectionMutation.only?(constr, keys, COMBINES)

        type =
          if keys.first == "::Hash#except"
            without(constr, record, arguments)
          elsif keys.first == "::Hash#merge" || built_by_combine?(constr, receiver)
            arguments.reduce(record) { |merged, argument| with_written(constr, merged, argument) or return nil }
          end
        type and [type, constr.add_typing(node, type: type).constr]
      end

      private

      def without(constr, record, arguments)
        removed = CollectionMutation.operand_types(constr, arguments) or return
        return unless removed.all? { |key| literal_key?(key) }

        names = removed.map(&:value)
        AST::Types::Record.new(elements: record.elements.except(*names), required_keys: record.required_keys - names)
      end

      def with_written(constr, record, argument)
        return unless argument.type == :hash || argument.type == :kwargs

        argument.children.reduce(record) do |merged, pair|
          return unless pair.type == :pair

          key, value = CollectionMutation.operand_types(constr, pair.children)
          value = storable_value(value)
          return unless literal_key?(key) && value

          AST::Types::Record.new(elements: merged.elements.merge(key.value => value), required_keys: merged.required_keys | [key.value])
        end
      end

      def built_by_combine?(constr, receiver)
        return false unless receiver&.type == :send && receiver.children[0]

        keys = hash_method_keys(constr, receiver.children[1], private: false)
        return false unless keys.size == 1 && COMBINES.include?(keys.first)

        keys.first != "::Hash#merge!" || built_by_combine?(constr, receiver.children[0])
      end
    end
  end
end
