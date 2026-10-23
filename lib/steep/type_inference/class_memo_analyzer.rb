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
      # of any other call; `:yielded` for a memo called on `self` and yielded
      # alone, with `called` the method that yields it; `:escape` for anything else — a value stored,
      # handed on or returned, or a name given to a call that reaches a method
      # or an ivar by it. `called` is the method called on it, and
      # `element_calls` the methods an iteration's block hands it elements to.
      # `within`: the class method whose body makes the use on `self`, outside
      # any block.
      #
      # Of a call of one of `names` (`calls`): `:statement` for one a statement
      # of a class body makes on `self`, outside any block, `:call` for any other, `:escape` for a
      # name given as a value; `called` is the method called.
      #
      # `forwarded_by`: on an escape, the method that returns the use, which
      # answers it to its callers. `at`: the call naming it, on an explicit
      # receiver (`site`). `direct`: the call is made on the value as written,
      # not on a local it was read into, and is no `op=` or target of a
      # multiple assignment. `key`: the symbol the call's first argument is
      # written as. `value`: on a read of one element (`KEY_READS`), the uses
      # of the element it answers, a call made on it in a statement of a class
      # body, on a hash `self` holds, a `:statement`.
      Use = Struct.new(:kind, :called, :element_calls, :within, :forwarded_by, :at, :direct, :key, :value) do
        def each_forwarder(&block)
          yield forwarded_by if forwarded_by
          value&.each { |use| use.each_forwarder(&block) }
        end
      end
      ESCAPE = Use.new(:escape, nil, Set[].freeze).freeze

      KEY_READS = %i[[]].freeze

      # Calls that reach a method or an ivar by a name given as a value.
      REFLECTIVE = %i[
        send __send__ public_send method public_method singleton_method define_singleton_method alias_method
        instance_variable_get instance_variable_set instance_variable_defined? remove_instance_variable
      ].freeze

      # Calls that run a string as code where the class's `self` may be.
      STRING_EVALS = %i[eval instance_eval class_eval module_eval class_exec].freeze

      OP_ASSIGNS = %i[op_asgn or_asgn and_asgn].freeze

      LOCAL_SCOPES = %i[def defs class module sclass].freeze


      def self.uses(node, names:)
        new(names).uses(node)
      end

      def self.calls(node, names:)
        new(names, calls: true).uses(node)
      end

      # How each call of one of `names` in `node` is made: `:replayed` on
      # `self` with a block a `yield` can check in place
      # (`ObjectStates::Yields`), `:blockless` with no block at all, `:other`
      # for any other call or mention.
      def self.block_calls(node, names:, found: Hash.new { |hash, name| hash[name] = [] })
        return found unless node.is_a?(::Parser::AST::Node)

        if Accumulators::LAMBDA_BODIES.include?(node.type) && names.include?(node.children[0].children[1])
          send = node.children[0]
          on_self = send.children[0].nil? || send.children[0].type == :self
          found[send.children[1]] << (on_self && ObjectStates::Yields.replayable?(node) ? :replayed : :other)
          send.children.drop(2).each { |child| block_calls(child, names: names, found: found) }
          node.children.drop(1).each { |child| block_calls(child, names: names, found: found) }
          return found
        end

        if %i[send csend].include?(node.type) && names.include?(node.children[1])
          found[node.children[1]] << (node.children.drop(2).any? { |argument| argument.type == :block_pass } ? :other : :blockless)
        elsif %i[sym str].include?(node.type) && names.include?(node.children[0].to_s.to_sym)
          found[node.children[0].to_s.to_sym] << :other
        end
        node.children.each { |child| block_calls(child, names: names, found: found) }
        found
      end

      # Where a call with an explicit receiver is, by the absolute path of its
      # source and the position of its method name.
      def self.site(node)
        selector = node.loc.selector or return
        "#{File.expand_path(node.loc.expression.source_buffer.name)}:#{selector.line}:#{selector.column}"
      end

      # `element_calls` for a block given by its parameters and body.
      def self.element_calls_in(params, body)
        new(Set[]).element_calls_in(params, body)
      end

      def initialize(names, calls: false)
        @names = names
        @calls = calls
        @uses = Hash.new { |hash, name| hash[name] = [] } #: Hash[Symbol, Array[Use]]
        @parents = {}.compare_by_identity #: Hash[::Parser::AST::Node, ::Parser::AST::Node?]
        @returned = {}.compare_by_identity #: Hash[::Parser::AST::Node, Set[::Parser::AST::Node]]
        @statements = Set[].compare_by_identity #: Set[::Parser::AST::Node]
      end

      def uses(node)
        walk(node, nil, statement: false, in_statement: false, on_class: true) if node.is_a?(::Parser::AST::Node)
        @uses
      end

      def element_calls_in(params, body)
        names = Set[] #: Set[Symbol]
        params.is_a?(Integer) ? names.merge((1..params).map { |index| :"_#{index}" }) : each_param(params) { |name| names << name }
        each_mention(body, nil, names).each_with_object(Set[]) do |(mention, parent), calls|
          read = element_read(mention, parent) or return
          calls << read if read.is_a?(Symbol)
        end
      end

      private

      # `statement`: whether `node` is a statement of a class or module body;
      # `in_statement`: whether its parent is. `on_class`: whether `self` may
      # be a class object here — anywhere but an instance method, outside a
      # block, whose `self` some call may change. `singleton_defs`: whether a
      # `def` here defines a method of the class object (`class << self`).
      def walk(node, parent, statement:, in_statement:, on_class:, singleton_defs: false)
        @parents[node] = parent
        @statements << node if statement
        case node.type
        when :class, :module, :sclass
          return walk_body(node)
        when :def, :block, :numblock
          return walk_children(node, statement: false, on_class: node.type != :def || singleton_defs)
        when :send, :csend
          @calls ? record_call(node, statement) : record_send(node, parent, in_statement)
        when :ivar
          record(node.children[0], node, parent, in_statement) if on_class && !@calls
        when :alias
          node.children.each { |name| @uses[name.children[0].to_sym] << ESCAPE if named?(name) }
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
        record(name, node, parent, in_statement)
        record_named(name, arguments)
      end

      def record_call(node, statement)
        receiver, name, *arguments = node.children
        if @names.include?(name)
          on_self = receiver.nil? || receiver.type == :self
          @uses[name] << Use.new((statement || in_class_statement?(node)) && on_self ? :statement : :call, name, Set[], on_self ? class_method_of(node) : nil)
        end
        record_named(name, arguments)
      end

      def record_named(name, arguments)
        if REFLECTIVE.include?(name)
          arguments.each { |argument| @uses[argument.children[0].to_sym] << ESCAPE if named?(argument) }
        elsif STRING_EVALS.include?(name)
          arguments.each { |argument| each_string(argument) { |text| escape_mentioned(text) } }
        end
      end

      def record(name, node, parent, in_statement)
        return unless @names.include?(name)

        uses = value_uses(node, parent, in_statement) || [ESCAPE]
        at = %i[send csend].include?(node.type) && node.children[0] && node.children[0].type != :self && ClassMemoAnalyzer.site(node)
        @uses[name].concat(at ? uses.map { |use| use.dup.tap { |sited| sited.at = at } } : uses)
      end

      def value_uses(node, parent, in_statement)
        if parent&.type == :yield && parent.children.size == 1 && node.type == :send && on_self?(node) && (method = enclosing_method(parent))
          [Use.new(:yielded, method, Set[])]
        elsif parent && %i[send csend].include?(parent.type) && parent.children[0].equal?(node)
          receiver_uses(node, parent, in_statement, direct: true)
        elsif parent&.type == :lvasgn
          local_uses(parent)
        elsif (method = returning_method(node))
          [Use.new(:escape, nil, Set[], nil, method)]
        elsif parent&.type == :block && parent.children[0].equal?(node)
          value_uses(parent, @parents[parent], in_statement)
        elsif discarded?(node, parent)
          []
        end
      end

      def discarded?(node, parent)
        case parent&.type
        when :class, :module, :sclass then true
        when :begin then !parent.children.last.equal?(node) || %i[class module sclass].include?(@parents[parent]&.type)
        else false
        end
      end

      def receiver_uses(node, call, in_statement, direct: false)
        element_calls = CollectionReaders::ITERATIONS.include?(call.children[1]) ? element_calls(call) : Set[]
        return unless element_calls

        on_self = on_self?(node)
        within = on_self ? class_method_of(call) : nil
        op_assigned = op_assigned?(call)
        direct &&= !op_assigned && @parents.fetch(call, nil)&.type != :mlhs
        key = call.children[2]&.type == :sym ? call.children[2].children[0] : nil
        use = Use.new(in_statement && on_self ? :statement : :receiver, call.children[1], element_calls, within, nil, nil, direct, key)
        use.value = element_uses(op_assigned ? @parents[call] : call) if KEY_READS.include?(use.called)
        op_assigned ? [Use.new(use.kind, :"#{use.called}=", Set[], within, nil, nil, nil, key), use] : [use]
      end

      # A hash `self` holds keeps its elements on `self` too.
      def on_self?(node)
        case node.type
        when :ivar then true
        when :send
          receiver = node.children[0]
          receiver.nil? || receiver.type == :self || (KEY_READS.include?(node.children[1]) && on_self?(receiver))
        else false
        end
      end

      def element_uses(read)
        parent = @parents[read]
        value_uses(read, parent, @statements.include?(parent)) || [ESCAPE]
      end

      # What a local is given here is used where the local is, when every
      # other mention of it, another assignment included, is the receiver of a
      # call.
      def local_uses(assignment)
        scope = assignment
        scope = @parents[scope] while @parents[scope] && !LOCAL_SCOPES.include?(scope.type)
        each_mention(scope, @parents[scope], Set[assignment.children[0]]).flat_map do |mention, parent|
          next [] if mention.equal?(assignment)

          (parent && %i[send csend].include?(parent.type) && parent.children[0].equal?(mention) && receiver_uses(mention, parent, false)) or return
        end
      end

      def returning_method(node)
        scope = @parents[node]
        scope = @parents[scope] until scope.nil? || LOCAL_SCOPES.include?(scope.type) || lambda?(scope)
        return unless scope && %i[def defs].include?(scope.type)

        returned = @returned[scope] ||= Set[].compare_by_identity.tap do |nodes|
          body = scope.children.last
          Accumulators.each_tail(body) { |value| nodes << value }
          Accumulators.each_returns(body) { |value| nodes << value }
        end
        scope.children[scope.type == :def ? 0 : 1] if returned.include?(node)
      end

      def lambda?(node)
        Accumulators::LAMBDA_BODIES.include?(node.type) && node.children[0].type == :lambda
      end

      # `call op= value` calls the writer of what `call` reads, too.
      def op_assigned?(call)
        assignment = @parents.fetch(call, nil)
        !assignment.nil? && OP_ASSIGNS.include?(assignment.type) && assignment.children[0].equal?(call)
      end

      # The methods an iteration's block hands each element to, when it names
      # them only as an argument of a call in `ElementReads`, or inside an
      # interpolation, which builds a new string. Nil for any other block.
      def element_calls(call)
        block = @parents[call]
        return unless block && %i[block numblock].include?(block.type) && block.children[0].equal?(call)

        _, params, body = block.children
        element_calls_in(params, body)
      end

      # The method `mention` is handed to, or true inside an interpolation.
      def element_read(mention, parent)
        return unless mention.type == :lvar && parent

        case parent.type
        when :send, :csend
          name = parent.children[1]
          return name if ElementReads::RECEIVER_NAMES.include?(name) && parent.children[0].equal?(mention)

          name if ElementReads::NAMES.include?(name) && parent.children.drop(2).any? { |argument| argument.equal?(mention) }
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

      # The method a `yield` runs in, or nil inside a block, whose `yield`
      # the replay does not reach.
      def enclosing_method(node)
        child = nil
        until node.nil? || %i[def defs].include?(node.type) || (Accumulators::LAMBDA_BODIES.include?(node.type) && !node.children[0].equal?(child))
          child = node
          node = @parents[node]
        end
        case node&.type
        when :def then node.children[0]
        when :defs then node.children[1]
        end
      end

      def in_class_statement?(node)
        child = node
        until (node = @parents[node]).nil? || LOCAL_SCOPES.include?(node.type)
          return false if Accumulators::LAMBDA_BODIES.include?(node.type) && !node.children[0].equal?(child)
          return true if @statements.include?(node)

          child = node
        end
        false
      end

      def class_method_of(node)
        name = enclosing_method(node) or return
        node = @parents[node] until %i[def defs].include?(node.type)
        parent = @parents[node]
        name if node.type == :defs ? node.children[0].type == :self : parent&.type == :sclass && parent.children[0].type == :self
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
