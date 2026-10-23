module Steep
  module TypeInference
    class ConstructorBindingAnalyzer
      # What a method's every returned value is (`Body#hands_back`,
      # `#hands_back_element`, `#hands_back_elements`).
      module HandedBack
        module_function

        def calls(body)
          names = Set[] #: Set[Symbol]
          returned = [] #: Array[::Parser::AST::Node]
          Accumulators.each_tail(body) { |node| returned << node }
          Accumulators.each_returns(body) { |node| returned << node }
          returned.each do |node|
            next if node.type == :yield
            receiver, name, *arguments = node.children
            return unless node.type == :send && (receiver.nil? || receiver.type == :self) && arguments.empty?

            names << name
          end
          names unless names.empty?
        end

        def element(args_node, body)
          positional = args_node.children.take_while { |param| %i[arg optarg].include?(param.type) }.map { |param| param.children[0] }
          found = Set[] #: Set[[Symbol, Integer]]
          builds = true
          returned = [] #: Array[::Parser::AST::Node]
          Accumulators.each_tail(body) { |node| returned << node }
          Accumulators.each_returns(body) { |node| returned << node }
          returned.each do |node|
            read = node.type == :or_asgn ? node.children[0] : node
            memo, method_name, key = read.children
            return unless read.type == :send && method_name == :[] && read.children.size == 3 && key.type == :lvar
            return unless memo&.type == :send && (memo.children[0].nil? || memo.children[0].type == :self) && memo.children.size == 2

            index = positional.index(key.children[0]) or return
            found << [memo.children[1], index]
            builds &&= node.type == :or_asgn && fresh_object?(node.children[1])
          end
          [*found.first, builds] if found.size == 1
        end

        def elements(body)
          memos = Set[] #: Set[Symbol]
          calls = Set[] #: Set[Symbol]
          Accumulators.each_tail(body) { |node| return unless element_returned?(node, memos, calls) }
          Accumulators.each_returns(body) { |node| return unless element_returned?(node, memos, calls) }
          [memos.first, calls] if memos.size <= 1 && !(memos.empty? && calls.empty?)
        end

        def element_returned?(node, memos, calls)
          return node.children.all? { |side| element_returned?(side, memos, calls) } if node.type == :or

          read = node.type == :or_asgn ? node.children[0] : node
          return false unless read.type == :send

          receiver, method_name, *arguments = read.children
          if method_name == :[]
            memo_read = receiver&.type == :send && on_self?(receiver.children[0]) && receiver.children.size == 2 && arguments.size == 1
            memos << receiver.children[1] if memo_read
            memo_read
          else
            calls << method_name if on_self?(receiver)
            on_self?(receiver)
          end
        end

        def on_self?(receiver)
          receiver.nil? || receiver.type == :self
        end

        def fresh_object?(node)
          receiver, method_name, *arguments = node.children
          node.type == :send && method_name == :new && arguments.empty? && receiver&.type == :const
        end
      end
    end
  end
end
