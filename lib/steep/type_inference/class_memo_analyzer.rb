module Steep
  module TypeInference
    # The objects a class keeps in an ivar of its own, built by a memo, and
    # every place the project names them (felixefelip/steep#205, stage 3):
    #
    #   class Base
    #     def self.settings = @settings ||= Settings.new   # the memo
    #   end
    #
    #   class Article < Base
    #     settings.name = :posts    # a call on it, as a statement of a class body
    #     define_named              # whose body reads `settings.name`
    #   end
    #
    # Names are matched by spelling alone, whoever the receiver is: a use this
    # cannot attribute to one class counts against every memo of that name.
    class ClassMemoAnalyzer
      # `kind`: `:statement` for the receiver of a call that is itself a
      # statement of a class body, made on `self`; `:receiver` for the receiver
      # of any other call; `:escape` for anything else — a value stored,
      # handed on, returned, or spelled as a symbol or a string. `called` is
      # the method called on it.
      Use = Struct.new(:kind, :called)
      ESCAPE = Use.new(:escape, nil).freeze

      Scan = Struct.new(:memos, :uses, keyword_init: true)

      def self.scan(node)
        new.scan(node)
      end

      def initialize
        @memos = {} #: Hash[String, Hash[Symbol, Array[[Symbol, String]?]]]
        @uses = Hash.new { |hash, name| hash[name] = [] } #: Hash[Symbol, Array[Use]]
      end

      def scan(node)
        walk(node, nil, [], false, false) if node.is_a?(::Parser::AST::Node)
        Scan.new(memos: @memos, uses: @uses)
      end

      private

      # `statement`: whether `node` is a statement of a class or module body.
      # `in_statement`: whether `parent` is.
      def walk(node, parent, nesting, statement, in_statement)
        case node.type
        when :class, :module
          const_node, *, body = node.children
          name = const_name(const_node)
          inner = name ? [*nesting, name] : nesting
          statements(body).each { |child| walk(child, node, inner, true, false) }
          return
        when :defs
          register_memo(node, nesting)
        when :send, :csend, :ivar
          record(node, parent, in_statement)
        when :ivasgn
          @uses[node.children[0]] << ESCAPE unless memo_write?(node, parent)
        when :sym, :str
          value = node.children[0]
          @uses[value.to_sym] << ESCAPE if value.is_a?(::String) || value.is_a?(::Symbol)
        end

        node.children.each { |child| walk(child, node, nesting, false, statement) if child.is_a?(::Parser::AST::Node) }
      end

      def record(node, parent, statement)
        name = node.type == :ivar ? node.children[0] : node.children[1]
        return unless node.type == :ivar || node.children.size == 2

        @uses[name] <<
          if parent && %i[send csend].include?(parent.type) && parent.children[0].equal?(node)
            on_self = node.type == :ivar || node.children[0].nil? || node.children[0].type == :self
            Use.new(statement && on_self ? :statement : :receiver, parent.children[1])
          else
            ESCAPE
          end
      end

      # `def self.name = @ivar ||= Klass.new`, or the same as the only
      # statement of a body.
      def register_memo(node, nesting)
        receiver, name, args, body = node.children
        return unless receiver.type == :self && args.children.empty? && !nesting.empty?

        memo = memo_of(body)
        ((@memos[nesting.join("::")] ||= {})[name] ||= []) << memo
      end

      def memo_of(body)
        return unless body&.type == :or_asgn

        target, value = body.children
        return unless target.type == :ivasgn && value.type == :send

        klass, method_name, *arguments = value.children
        klass_name = const_name(klass)
        [target.children[0], klass_name] if method_name == :new && arguments.empty? && klass_name
      end

      def memo_write?(node, parent)
        parent&.type == :or_asgn && parent.children[0].equal?(node) && memo_of(parent)
      end

      def statements(body)
        return [] unless body.is_a?(::Parser::AST::Node)

        body.type == :begin ? body.children : [body]
      end

      def const_name(node)
        return unless node.is_a?(::Parser::AST::Node) && node.type == :const

        scope, name = node.children
        case scope&.type
        when nil, :cbase then name.to_s
        when :const then (prefix = const_name(scope)) && "#{prefix}::#{name}"
        end
      end
    end
  end
end
