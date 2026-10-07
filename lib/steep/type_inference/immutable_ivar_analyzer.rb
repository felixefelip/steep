module Steep
  module TypeInference
    # The facts one source contributes to which instance variables of a class are
    # fixed for life by `initialize` (felixefelip/steep#205, stage 1):
    #
    #   class Reflection
    #     attr_reader :name
    #     def initialize(name) = @name = name   # `@name` <- argument 0
    #   end
    #
    # An object built by `Reflection.new(:posts)` then holds `:posts` in `@name`
    # until it is collected, under any name that reaches it. That is what lets the
    # value travel with the object: nothing it is handed to can change it.
    #
    # One source never decides that on its own: a reopen in another file, a
    # `class_eval` block, an `instance_variable_set` anywhere can write the ivar.
    # So this only COLLECTS, per file, and `Project::ConstructorBindingRegistry`
    # decides over all of them. Every fact here errs one way: something this
    # cannot read is recorded as a write.
    class ImmutableIvarAnalyzer
      # What one class's bodies in one source say. `bindings` is nil where the
      # source has no instance `initialize` for the class, and `initializers`
      # counts them: two, in one file or across files, and which one runs is a
      # question of load order.
      ClassFacts = Struct.new(:bindings, :initializers, :written, :superclass, :mixins, keyword_init: true) do
        def self.empty
          new(bindings: nil, initializers: 0, written: Set[], superclass: false, mixins: false)
        end
      end

      # `classes` by name; `tainted` the ivar names something writes on an object
      # this cannot name; `taint_all` where even the name is unknown
      # (`instance_variable_set(name, …)`).
      #
      # `module_writes` are the ivars a module's instance methods write, and
      # `extends_objects` whether anything gives ONE object a module's methods
      # (`obj.extend(M)`). Together they are what an `extend` can write: the
      # class of that object is not known, but the methods it gains are a
      # module's.
      Scan = Struct.new(:classes, :tainted, :taint_all, :module_writes, :extends_objects, keyword_init: true)

      IVAR_WRITES = %i[ivasgn].freeze
      EVAL_BLOCKS = %i[class_eval class_exec module_eval module_exec].freeze
      INSTANCE_EVAL_BLOCKS = %i[instance_eval instance_exec].freeze
      IVAR_SETTERS = %i[instance_variable_set remove_instance_variable].freeze
      SEND_METHODS = %i[send public_send __send__].freeze
      # Classes every object is an instance of: a method written on one of them
      # runs on a `Reflection` as much as on anything else.
      UNIVERSAL = %w[Object BasicObject Kernel].freeze

      def self.analyze(node)
        new.analyze(node)
      end

      def initialize
        @classes = {} #: Hash[String, ClassFacts]
        @tainted = Set[] #: Set[Symbol]
        @taint_all = false
        @modules = Set[] #: Set[String]
        @module_writes = Set[] #: Set[Symbol]
        @extends_objects = false
      end

      def analyze(node)
        walk(node, nesting: [], owner: nil, side: :top) if node.is_a?(::Parser::AST::Node)
        Scan.new(
          classes: @classes, tainted: @tainted, taint_all: @taint_all,
          module_writes: @module_writes, extends_objects: @extends_objects
        )
      end

      private

      # `owner` is the class whose instance ivars an `@x = …` here writes, or nil
      # where it is not an instance of a class this can name. `side` says what
      # `self` is: `:instance` inside an instance method or a block that may run
      # on an instance, `:class` in a class body or singleton method, `:top` at
      # the top level.
      def walk(node, nesting:, owner:, side:)
        case node.type
        when :class
          const_node, superclass, body = node.children
          name = qualified(const_node, nesting) or return walk_children(node, nesting: nesting, owner: nil, side: :top)
          facts = facts_for(name)
          facts.superclass = true if superclass
          walk(body, nesting: name.split("::"), owner: name, side: :class) if body
        when :module
          const_node, body = node.children
          name = qualified(const_node, nesting)
          @modules << name if name
          # A module's instance methods run on whatever includes it, which this
          # does not follow: its writes are recorded under its own name, and the
          # class that mixes it in is marked by `mixins`.
          walk(body, nesting: name ? name.split("::") : nesting, owner: name, side: :class) if body
        when :sclass
          # `class << self` and `class << obj`: singleton methods, whose ivars are
          # the class's or that object's own, not an instance's.
          walk(node.children[1], nesting: nesting, owner: owner, side: :singleton) if node.children[1]
        when :def
          name, args, body = node.children
          if side == :class && name == :initialize && owner
            record_initialize(owner, args, body)
          elsif body
            walk(body, nesting: nesting, owner: owner, side: side == :singleton ? :singleton : :instance)
          end
        when :defs
          receiver, _name, _args, body = node.children
          if receiver.type == :self
            walk(body, nesting: nesting, owner: owner, side: :singleton) if body
          else
            # `def obj.x`: a method on one object this cannot name, which writes
            # that object's ivars.
            each_ivar_write(body) { |name| @tainted << name }
            walk(body, nesting: nesting, owner: nil, side: :top) if body
          end
        when :block, :numblock, :itblock
          walk_block(node, nesting: nesting, owner: owner, side: side)
        when :send
          walk_send(node, nesting: nesting, owner: owner, side: side)
        when *IVAR_WRITES
          record_write(owner, side, node.children[0])
          walk_children(node, nesting: nesting, owner: owner, side: side)
        else
          walk_children(node, nesting: nesting, owner: owner, side: side)
        end
      end

      def walk_children(node, nesting:, owner:, side:)
        node.children.each do |child|
          walk(child, nesting: nesting, owner: owner, side: side) if child.is_a?(::Parser::AST::Node)
        end
      end

      def walk_block(node, nesting:, owner:, side:)
        send_node, _params, body = node.children
        receiver, method_name, = send_parts(send_node)

        walk(send_node, nesting: nesting, owner: owner, side: side)
        return unless body

        if EVAL_BLOCKS.include?(method_name) && receiver && !(named = candidates(receiver, nesting)).empty?
          # `Reflection.class_eval { … }` is a reopen written as a block, and is
          # read as one — under every class the constant may name.
          named.each { |name| walk(body, nesting: name.split("::"), owner: name, side: :class) }
        elsif INSTANCE_EVAL_BLOCKS.include?(method_name)
          # Runs on whatever the receiver is, which may be one of ours.
          each_ivar_write(body) { |name| @tainted << name }
          walk(body, nesting: nesting, owner: nil, side: :top)
        else
          # A block in a class body may run on an instance — `define_method`,
          # a callback, an `included do` — and one inside a method runs where
          # the method does.
          walk(body, nesting: nesting, owner: owner, side: side == :singleton ? :singleton : :instance)
        end
      end

      def walk_send(node, nesting:, owner:, side:)
        receiver, method_name, arguments = send_parts(node)

        if IVAR_SETTERS.include?(method_name)
          name = literal_name(arguments.first)
          if name.nil?
            @taint_all = true
          elsif receiver.nil? || receiver.type == :self
            record_write(owner, side, name)
          else
            @tainted << name
          end
        elsif side == :class && receiver.nil? && owner
          case method_name
          when :attr_writer, :attr_accessor
            arguments.each { |argument| (name = literal_name(argument)) && facts_for(owner).written << :"@#{name}" }
          when :include, :prepend
            facts_for(owner).mixins = true
          end
        elsif %i[include prepend].include?(method_name) && receiver && !(named = candidates(receiver, nesting)).empty?
          named.each { |name| facts_for(name).mixins = true }
        elsif method_name == :extend && extends_an_object?(receiver, nesting, side)
          # `obj.extend(M)` gives ONE object M's methods, and this cannot tell
          # which object.
          @extends_objects = true
        end

        walk_children(node, nesting: nesting, owner: owner, side: side)
      end

      def record_initialize(owner, args, body)
        facts = facts_for(owner)
        facts.initializers += 1
        facts.bindings = initialize_bindings(args, body)
      end

      # `@x = param` statements at the top of `initialize`, by ivar, for a plain
      # positional `param`. An ivar `initialize` writes in any other way, or more
      # than once, is not bound to an argument: its value at exit depends on the
      # flow, which this does not read.
      def initialize_bindings(args, body)
        positions = {} #: Hash[Symbol, Integer]
        args&.children&.each_with_index do |arg, index|
          positions[arg.children[0]] = index if arg.is_a?(::Parser::AST::Node) && %i[arg optarg].include?(arg.type)
        end

        writes = Hash.new(0) #: Hash[Symbol, Integer]
        each_ivar_write(body) { |name| writes[name] += 1 }

        bindings = {} #: Hash[Symbol, Integer]
        each_statement(body) do |statement|
          next unless statement.type == :ivasgn

          name, value = statement.children
          next unless value.is_a?(::Parser::AST::Node) && value.type == :lvar && writes[name] == 1

          index = positions[value.children[0]]
          bindings[name] = index if index
        end
        bindings
      end

      # `base.extend(M)` in an `included` hook, `extend M` inside an instance
      # method. Not `Foo.extend(M)` or `extend M` in a class body, which give a
      # CLASS singleton methods: those write the class's ivars, not an
      # instance's.
      def extends_an_object?(receiver, nesting, side)
        if receiver.nil? || receiver.type == :self
          side == :instance
        else
          candidates(receiver, nesting).empty?
        end
      end

      def record_write(owner, side, name)
        return unless side == :instance

        @module_writes << name if owner && @modules.include?(owner)

        if owner.nil? || UNIVERSAL.include?(owner)
          @tainted << name
        else
          facts_for(owner).written << name
        end
      end

      def each_ivar_write(node, &block)
        return unless node.is_a?(::Parser::AST::Node)

        yield node.children[0] if IVAR_WRITES.include?(node.type)
        node.children.each { |child| each_ivar_write(child, &block) }
      end

      def each_statement(body, &block)
        return unless body.is_a?(::Parser::AST::Node)

        statements = body.type == :begin ? body.children : [body]
        statements.each { |statement| yield statement if statement.is_a?(::Parser::AST::Node) }
      end

      def facts_for(name)
        @classes[name] ||= ClassFacts.empty
      end

      # `send(:instance_variable_set, …)` is the call it names.
      def send_parts(node)
        receiver, method_name, *arguments = node.children
        if SEND_METHODS.include?(method_name) && (dispatched = literal_name(arguments.first))
          return [receiver, dispatched.to_sym, arguments.drop(1)]
        end

        [receiver, method_name, arguments]
      end

      def literal_name(node)
        return nil unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :sym then node.children[0]
        when :str then node.children[0].to_sym
        end
      end

      # Every class a constant written here may name, innermost first: `Foo`
      # inside `module A; module B` is `A::B::Foo`, `A::Foo` or `Foo`, by
      # whichever is defined, which one source cannot tell.
      def candidates(const_node, nesting)
        name = const_name(const_node) or return []
        return [name] if const_node.children[0]&.type == :cbase

        nesting.size.downto(0).map { |depth| [*nesting.take(depth), name].join("::") }
      end

      def qualified(const_node, nesting)
        name = const_name(const_node) or return nil
        const_node.children[0]&.type == :cbase || nesting.empty? ? name : [*nesting, name].join("::")
      end

      def const_name(node)
        return nil unless node.is_a?(::Parser::AST::Node) && node.type == :const

        scope, name = node.children
        case scope&.type
        when nil, :cbase then name.to_s
        when :const then (prefix = const_name(scope)) && "#{prefix}::#{name}"
        end
      end
    end
  end
end
