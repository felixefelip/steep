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
      # or an ivar by it. `called` is the method called on it, and
      # `element_calls` the methods an iteration's block hands it elements to.
      Use = Struct.new(:kind, :called, :element_calls)
      ESCAPE = Use.new(:escape, nil, Set[].freeze).freeze

      # Calls that reach a method or an ivar by a name given as a value.
      REFLECTIVE = %i[
        send __send__ public_send method public_method singleton_method define_singleton_method
        instance_variable_get instance_variable_set instance_variable_defined? remove_instance_variable
      ].freeze

      # Calls that run a string as code where the class's `self` may be.
      STRING_EVALS = %i[eval instance_eval class_eval module_eval class_exec].freeze

      # Calls that hand each element of a collection to a block and change
      # nothing themselves. A use as their receiver counts only with a block
      # whose parameters reach nothing that may change an element.
      ITERATIONS = %i[each map collect filter_map select filter reject find detect any? all? none? each_with_index].freeze

      # Core methods that neither change nor keep a value passed to them as an
      # argument: what a block may hand an element to. Whether the project
      # redefines one is `ObjectStates`' question.
      ARGUMENT_READS = %i[
        sub sub! gsub gsub! match match? =~ === == != eql? equal? start_with? end_with? include?
        index rindex tr delete count scan split partition rpartition casecmp casecmp? <=> + %
      ].freeze

      def self.uses(node, names:)
        new(names).uses(node)
      end

      def initialize(names)
        @names = names
        @uses = Hash.new { |hash, name| hash[name] = [] } #: Hash[Symbol, Array[Use]]
        @parents = {}.compare_by_identity #: Hash[::Parser::AST::Node, ::Parser::AST::Node?]
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
        @parents[node] = parent
        case node.type
        when :class, :module, :sclass
          return walk_body(node)
        when :def, :block, :numblock
          return walk_children(node, statement: false, on_class: node.type != :def || singleton_defs)
        when :send, :csend
          record_send(node, parent, in_statement)
        when :ivar
          record(node.children[0], node, parent, in_statement) if on_class
        end

        walk_children(node, statement: statement, on_class: on_class)
      end

      # A class or module body runs its statements on the class; `class << self`
      # defines its methods there.
      def walk_body(node)
        singleton = node.type == :sclass
        each_statement(node.children.last) do |child|
          walk(child, node, statement: !singleton, in_statement: false, on_class: true, singleton_defs: singleton)
        end
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
            element_calls = ITERATIONS.include?(parent.children[1]) ? element_calls(parent) : Set[]
            return @uses[name] << ESCAPE unless element_calls

            on_self = node.type == :ivar || node.children[0].nil? || node.children[0].type == :self
            Use.new(in_statement && on_self ? :statement : :receiver, parent.children[1], element_calls)
          else
            ESCAPE
          end
      end

      # The methods an iteration's block hands each element to, when it names
      # them only as an argument of a call in `ARGUMENT_READS`, or inside an
      # interpolation, which builds a new string. Nil for any other block.
      def element_calls(call)
        block = @parents[call]
        return unless block && %i[block numblock].include?(block.type) && block.children[0].equal?(call)

        _, params, body = block.children
        names = Set[] #: Set[Symbol]
        each_param(params) { |name| names << name }
        each_mention(body, nil, names).each_with_object(Set[]) do |(mention, parent), calls|
          read = element_read(mention, parent) or return
          calls << read if read.is_a?(Symbol)
        end
      end

      # The method `mention` is handed to, or true inside an interpolation.
      def element_read(mention, parent)
        return unless mention.type == :lvar && parent

        case parent.type
        when :send, :csend
          parent.children[1] if ARGUMENT_READS.include?(parent.children[1]) && parent.children.drop(2).any? { |argument| argument.equal?(mention) }
        when :begin
          @parents.fetch(parent, nil)&.type == :dstr || nil
        end
      end

      def each_param(node, &block)
        return unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :arg, :procarg0, :optarg, :restarg, :blockarg, :shadowarg
          name = node.children[0]
          name.is_a?(Symbol) ? yield(name) : node.children.each { |child| each_param(child, &block) }
        else
          node.children.each { |child| each_param(child, &block) }
        end
      end

      # `[node, parent]` for every read or write of one of `names` in `node`.
      def each_mention(node, parent, names, found = [])
        return found unless node.is_a?(::Parser::AST::Node)

        @parents[node] ||= parent
        found << [node, parent] if %i[lvar lvasgn].include?(node.type) && names.include?(node.children[0])
        node.children.each { |child| each_mention(child, node, names, found) }
        found
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
