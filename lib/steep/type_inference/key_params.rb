module Steep
  module TypeInference
    # The parameter a one-key read is made with, where the key is a parameter
    # of the method the read is written in, as passed: its position.
    #
    #   def [](key) = @backend[key]     # 0
    module KeyParams
      # The local a one-key call passes, outside any block.
      def self.local(call, parents)
        key = call.children[2]
        return unless call.children.size == 3 && key.type == :lvar

        node = parents[call]
        node = parents[node] until node.nil? || %i[def defs block numblock].include?(node.type)
        key.children[0] unless node && %i[block numblock].include?(node.type)
      end

      # `uses`, each read whose key is a parameter `body` never assigns told
      # that parameter's position.
      def self.placed(uses, args_node, body)
        positional = args_node ? args_node.children.take_while { |param| %i[arg optarg].include?(param.type) }.map { |param| param.children[0] } : []
        uses.each_value do |list|
          list.each do |use|
            next unless use.key_local

            index = positional.index(use.key_local)
            use.key_param = index if index && !assigns?(body, use.key_local)
          end
        end
        uses
      end

      def self.assigns?(node, name)
        return false unless node.is_a?(::Parser::AST::Node)
        return true if node.type == :lvasgn && node.children[0] == name

        node.children.any? { |child| assigns?(child, name) }
      end
    end
  end
end
