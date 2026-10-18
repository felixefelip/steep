module Steep
  # What `ArrayMutation` and `HashMutation` ask of a call alike.
  module CollectionMutation
    # What any object answers without changing it or handing out its contents.
    OBJECT_READS = (
      %w[!~ class clone dup frozen? instance_of? is_a? itself kind_of? nil? object_id respond_to?]
        .map { |name| "::Kernel##{name}" } +
      %w[! != equal? __id__].map { |name| "::BasicObject##{name}" }
    ).freeze

    class << self
      # Whether every method a call may resolve to is one of `allowed`, and the
      # project replaced none of them.
      def only?(constr, keys, allowed)
        !keys.empty? && keys.all? { |key| allowed.include?(key) && !constr.literal_method_registry.blocked?(key) }
      end

      # Whether `receiver` reads an ivar whose contents the body was entered
      # with. Its tuple or record is then what it holds: every call that may
      # change it widens it or folds onto it.
      def entered_with?(constr, receiver)
        return false unless receiver&.type == :ivar

        def_node = constr.method_context&.node or return false
        constr.specialization_arguments(def_node)&.self_ivars&.key?(receiver.children[0]) || false
      end

      # Each argument's type as an operand, or nil where one is not typed.
      def operand_types(constr, arguments)
        arguments.map do |argument|
          return nil unless constr.typing.has_type?(argument)

          constr.literal_operand_type(argument, constr.typing.type_of(node: argument))
        end
      end
    end
  end
end
