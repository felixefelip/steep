module Steep
  # The key a `Hash.new` block receives: `rb_hash_aref` runs the block with
  # the key a read does not find. Where the hash is a local nothing else
  # names (`HeldLocals#held?`) and every mention of it is a read, a store or
  # a query by key, every run of the block is one of those reads, so its key
  # is one of theirs: a literal, or a parameter the body does not reassign,
  # whose types are known where the block is written.
  module HashMutation
    KEYED_MENTIONS = %i[[] []= store key? has_key? include? member?].freeze

    LITERAL_KEYS = %i[sym str int].freeze

    class << self
      # `params`, a `Hash.new` block's, with the key read as the keys the
      # hash's reads pass.
      def default_block_params(constr, node, receiver_type, params)
        return params unless params && params.required.size == 2 && params.optional.empty? && !params.rest && !params.has_keywords?
        return params unless node.type == :block && fresh_hash_call?(node.children[0], receiver_type)

        return params if reads_own_hash?(node)

        keys = default_block_keys(constr, node) || IvarReadKeys.of(constr, node) or return params
        key = AST::Types::Union.build(types: keys)
        return params unless constr.check_relation(sub_type: key, super_type: params.required[1]).success?

        Interface::Function::Params.build(required: [params.required[0], key])
      end

      def default_block_keys(constr, node)
        name = constr.method_context&.held_locals&.held_name(node) or return
        def_node = constr.method_context.node
        body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
        keys = [] #: Array[AST::Types::t]
        each_mention(body, name, nil) do |parent|
          return unless parent&.type == :send && parent.children[0]&.type == :lvar && parent.children[0].children[0] == name && KEYED_MENTIONS.include?(parent.children[1])
          next unless parent.children[1] == :[]

          keys << (read_key_type(constr, def_node, parent.children[2..]) || (return))
        end
        keys unless keys.empty?
      end

      def reads_own_hash?(block)
        hash = block.children[1].children[0]&.children&.first
        found = false
        each_mention(block.children[2], hash, nil) { found = true } if hash
        found
      end

      def fresh_hash_call?(send, receiver_type)
        send.type == :send && send.children[1] == :new &&
          receiver_type.is_a?(AST::Types::Name::Singleton) && receiver_type.name == AST::Builtin::Hash.module_name
      end

      def each_mention(node, name, parent, &block)
        return unless node.is_a?(::Parser::AST::Node)

        yield parent if node.type == :lvar && node.children[0] == name
        node.children.each { |child| each_mention(child, name, node, &block) }
      end

      def read_key_type(constr, def_node, arguments)
        return unless arguments.size == 1

        key = arguments[0]
        return AST::Types::Literal.new(value: key.children[0]) if LITERAL_KEYS.include?(key.type)
        return unless key.type == :lvar && parameter?(def_node, key.children[0]) && !constr.method_context.reassigned_parameter?(key.children[0])

        constr.context.type_env[key.children[0]]
      end

      def parameter?(def_node, name)
        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        args.children.any? { |arg| %i[arg optarg].include?(arg.type) && arg.children[0] == name }
      end
    end
  end
end
