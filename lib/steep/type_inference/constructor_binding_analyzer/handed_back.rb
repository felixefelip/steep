module Steep
  module TypeInference
    class ConstructorBindingAnalyzer
      # What a method's every returned value is (`Body#hands_back`,
      # `#hands_back_element`, `#hands_back_elements`, `#keyed_memo`).
      module HandedBack
        module_function

        def calls(body)
          names = Set[] #: Set[Symbol]
          Accumulators::ReturnedValues.each_value(body) do |node|
            next if node.type == :yield
            return unless node.type == :send && ObjectStates.on_self?(node) && node.children.size == 2

            names << node.children[1]
          end
          names unless names.empty?
        end

        def element(args_node, body)
          positional = args_node.children.take_while { |param| %i[arg optarg].include?(param.type) }.map { |param| param.children[0] }
          found = Set[] #: Set[[Symbol, Integer]]
          builds = true
          Accumulators::ReturnedValues.each_value(body) do |node|
            read = node.type == :or_asgn ? node.children[0] : node
            memo, method_name, key = read.children
            return unless read.type == :send && method_name == :[] && read.children.size == 3 && key.type == :lvar

            name = memo_name(memo) or return
            index = positional.index(key.children[0]) or return
            found << [name, index]
            builds &&= node.type == :or_asgn && fresh_object?(node.children[1])
          end
          [*found.first, builds] if found.size == 1
        end

        def stored_element(args_node, body)
          body = body.children[0] while body&.type == :begin && body.children.size == 1
          return unless body&.type == :send && body.children.size == 4

          memo, method_name, key, value = body.children
          return unless memo&.type == :ivar && method_name == :[]= && key.type == :lvar && value.type == :lvar

          positional = args_node.children.take_while { |param| %i[arg optarg].include?(param.type) }.map { |param| param.children[0] }
          key_index = positional.index(key.children[0]) or return
          value_index = positional.index(value.children[0]) or return
          [memo.children[0], key_index, value_index]
        end

        def block_super(body)
          return unless body&.type == :block && body.children[2]&.type == :zsuper && body.children[1].children.empty?

          receiver, method_name, *arguments = body.children[0].children
          [receiver.children[0], method_name] if receiver&.type == :ivar && arguments.empty?
        end

        def elements(body)
          memos = Set[] #: Set[Symbol]
          calls = Set[] #: Set[Symbol]
          Accumulators::ReturnedValues.each_value(body, logic: true) { |node| return unless element_returned?(node, memos, calls) }
          [memos.first, calls] if memos.size <= 1 && !(memos.empty? && calls.empty?)
        end

        def element_returned?(node, memos, calls)
          read = node.type == :or_asgn ? node.children[0] : node
          return false unless read.type == :send

          receiver, method_name, *arguments = read.children
          if method_name == :[]
            memo = memo_name(receiver) if arguments.size == 1
            memos << memo if memo
            !memo.nil?
          else
            calls << method_name if ObjectStates.on_self?(read)
            ObjectStates.on_self?(read)
          end
        end

        # How a call reaches a memo's hash: by the memo's name, called on
        # `self` with nothing, or by the ivar that holds it.
        def memo_name(node)
          return node.children[0] if node&.type == :ivar

          node.children[1] if node&.type == :send && ObjectStates.on_self?(node) && node.children.size == 2
        end

        # `[read, value]` where a hash's own method ends `read || store(key,
        # value)`, `read` being `super` or `self[key]` and `key` its first
        # parameter, and stores nothing anywhere else.
        def keyed_memo(args_node, body)
          key = args_node.children.first
          return unless key&.type == :arg && body

          *before, tail = body.type == :begin ? body.children : [body]
          return unless tail&.type == :or

          read, stored = tail.children
          _, method_name, stored_key, value = stored.children
          return unless stored.type == :send && ObjectStates.on_self?(stored) && method_name == :store && stored.children.size == 4
          return unless stored_key.type == :lvar && stored_key.children[0] == key.children[0] && entry_read?(read, key.children[0])

          [read, value] unless [*before, read, value].any? { |node| stores?(node) }
        end

        def entry_read?(node, key)
          return true if node.type == :zsuper

          node.type == :send && ObjectStates.on_self?(node) && node.children[1] == :[] && node.children[2..] == [s_lvar(key)]
        end

        def s_lvar(name) = ::Parser::AST::Node.new(:lvar, [name])

        def stores?(node)
          return false unless node.is_a?(::Parser::AST::Node)
          return true if node.type == :send && ObjectStates.on_self?(node) && node.children[1] == :store

          node.children.any? { |child| stores?(child) }
        end

        def fresh_object?(node)
          receiver, method_name, *arguments = node.children
          node.type == :send && method_name == :new && arguments.empty? && receiver&.type == :const
        end
      end
    end
  end
end
