module Steep
  module TypeInference
    class ConstructorBindingAnalyzer
      # What a method's every returned value is (`Body#hands_back`,
      # `#hands_back_element`, `#hands_back_elements`, `#keyed_memo`).
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

        # The value a hash's own method stores under its first parameter when
        # it holds nothing there, where its body ends `super || store(key,
        # value)` and nothing before writes the hash.
        def keyed_memo(args_node, body)
          key = args_node.children.first
          return unless key&.type == :arg && body

          *before, tail = body.type == :begin ? body.children : [body]
          return unless tail&.type == :or && before.none? { |statement| writes_entries?(statement) }

          read, stored = tail.children
          receiver, method_name, stored_key, value = stored.children
          return unless stored.type == :send && on_self?(receiver) && method_name == :store && stored.children.size == 4
          return unless stored_key.type == :lvar && stored_key.children[0] == key.children[0] && entry_read?(read, key.children[0])

          value unless writes_entries?(value)
        end

        def entry_read?(node, key)
          return true if node.type == :zsuper

          node.type == :send && on_self?(node.children[0]) && node.children[1] == :[] && node.children[2..] == [s_lvar(key)]
        end

        def s_lvar(name) = ::Parser::AST::Node.new(:lvar, [name])

        def writes_entries?(node)
          return false unless node.is_a?(::Parser::AST::Node)
          return true if node.type == :send && on_self?(node.children[0]) && ENTRY_WRITERS.include?(node.children[1])

          node.children.any? { |child| writes_entries?(child) }
        end

        # What changes a hash's entries, called on the hash.
        ENTRY_WRITERS = %i[
          []= store delete clear replace merge! update shift keep_if select! filter! reject! delete_if compact!
          transform_values! transform_keys! default= default_proc= compare_by_identity rehash
        ].to_set.freeze

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
