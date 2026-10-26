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
            return unless memo_reader?(memo)

            index = positional.index(key.children[0]) or return
            found << [memo.children[1], index]
            builds &&= node.type == :or_asgn && fresh_object?(node.children[1])
          end
          [*found.first, builds] if found.size == 1
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
            memo_read = memo_reader?(receiver) && arguments.size == 1
            memos << receiver.children[1] if memo_read
            memo_read
          else
            calls << method_name if ObjectStates.on_self?(read)
            ObjectStates.on_self?(read)
          end
        end

        def memo_reader?(node)
          node&.type == :send && ObjectStates.on_self?(node) && node.children.size == 2
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
