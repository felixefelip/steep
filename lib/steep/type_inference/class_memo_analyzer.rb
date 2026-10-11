module Steep
  module TypeInference
    # Where a source names one of the class memos the project defines
    # (`ConstructorBindingAnalyzer::Body#memo`), or its ivar, by spelling
    # (felixefelip/steep#205, stage 3):
    #
    #   class Article < Base
    #     settings.name = :posts    # the receiver of a statement of a class body
    #     define_named              # whose body reads `settings.name`
    #   end
    #
    # A use this cannot attribute to one class counts against every memo of
    # that name. Writes to the ivar are the postconditions' `may_write`, not
    # this.
    class ClassMemoAnalyzer
      # `kind`: `:statement` for the receiver of a call that is itself a
      # statement of a class body, made on `self`; `:receiver` for the receiver
      # of any other call; `:escape` for anything else — a value stored,
      # handed on or returned, or a name given to a call that reaches a method
      # or an ivar by it. `called` is the method called on it.
      Use = Struct.new(:kind, :called)
      ESCAPE = Use.new(:escape, nil).freeze

      # Calls that reach a method or an ivar by a name given as a value.
      REFLECTIVE = %i[
        send __send__ public_send method public_method singleton_method define_singleton_method
        instance_variable_get instance_variable_set instance_variable_defined? remove_instance_variable
      ].freeze

      # Calls that run a string as code where the class's `self` may be.
      STRING_EVALS = %i[eval instance_eval class_eval module_eval class_exec].freeze

      def self.uses(node, names:)
        new(names).uses(node)
      end

      def initialize(names)
        @names = names
        @uses = Hash.new { |hash, name| hash[name] = [] } #: Hash[Symbol, Array[Use]]
      end

      def uses(node)
        walk(node, nil, statement: false, in_statement: false, on_class: true) if node.is_a?(::Parser::AST::Node)
        @uses
      end

      private

      # `statement`: whether `node` is a statement of a class or module body;
      # `in_statement`: whether its parent is. `on_class`: whether `self` may
      # be a class object here — anywhere but an instance method, outside a
      # block, whose `self` some call may change. `singleton_defs`: whether a
      # `def` here defines a method of the class object (`class << self`).
      def walk(node, parent, statement:, in_statement:, on_class:, singleton_defs: false)
        case node.type
        when :class, :module
          body = node.children.last
          each_statement(body) { |child| walk(child, node, statement: true, in_statement: false, on_class: true) }
          return
        when :sclass
          each_statement(node.children[1]) { |child| walk(child, node, statement: false, in_statement: false, on_class: true, singleton_defs: true) }
          return
        when :def
          walk_children(node, statement: false, on_class: singleton_defs)
          return
        when :block, :numblock
          walk_children(node, statement: false, on_class: true)
          return
        when :send, :csend
          record_send(node, parent, in_statement)
        when :ivar
          record(node.children[0], node, parent, in_statement) if on_class
        end

        walk_children(node, statement: statement, on_class: on_class)
      end

      def walk_children(node, statement:, on_class:)
        node.children.each do |child|
          walk(child, node, statement: false, in_statement: statement, on_class: on_class) if child.is_a?(::Parser::AST::Node)
        end
      end

      def record_send(node, parent, in_statement)
        _, name, *arguments = node.children
        record(name, node, parent, in_statement) if arguments.empty?
        if REFLECTIVE.include?(name)
          arguments.each { |argument| @uses[argument.children[0].to_sym] << ESCAPE if named?(argument) }
        elsif STRING_EVALS.include?(name)
          arguments.each { |argument| each_string(argument) { |text| escape_mentioned(text) } }
        end
      end

      def record(name, node, parent, in_statement)
        return unless @names.include?(name)

        @uses[name] <<
          if parent && %i[send csend].include?(parent.type) && parent.children[0].equal?(node)
            on_self = node.type == :ivar || node.children[0].nil? || node.children[0].type == :self
            Use.new(in_statement && on_self ? :statement : :receiver, parent.children[1])
          else
            ESCAPE
          end
      end

      def named?(node)
        %i[sym str].include?(node.type) && @names.include?(node.children[0].to_sym)
      end

      def each_string(node, &block)
        return unless node.is_a?(::Parser::AST::Node)

        yield node.children[0] if node.type == :str
        node.children.each { |child| each_string(child, &block) }
      end

      def escape_mentioned(text)
        @names.each { |name| @uses[name] << ESCAPE if text.match?(/(?<![\w@])#{Regexp.escape(name.to_s)}(?!\w)/) }
      end

      def each_statement(body, &block)
        return unless body.is_a?(::Parser::AST::Node)

        (body.type == :begin ? body.children : [body]).each(&block)
      end
    end
  end
end
