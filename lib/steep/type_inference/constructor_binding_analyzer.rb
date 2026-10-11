module Steep
  module TypeInference
    # Walks a parsed Ruby AST and, for each class, maps an attr-style reader
    # method to the *positional constructor parameter* its backing ivar is
    # assigned from:
    #
    #   class Proxy
    #     def initialize(klass, owner); @owner = owner; end
    #     def owner; @owner; end
    #   end
    #   # => { "Proxy" => { owner: 1 } }
    #
    # Consumed by `TypeConstruction` at `.new` call sites to translate an
    # `initialize` precondition on `self.<reader>...` into an obligation on the
    # matching constructor argument (felixefelip/steep#60): given
    # `Proxy#initialize requires not_nil self.owner.user`, a call
    # `Proxy.new(klass, self)` implies `not_nil self.user` on the enclosing
    # method, because `@owner` is bound to argument index 1 (`self`).
    #
    # Detection is purely syntactic and conservative: a reader qualifies only
    # when its body is exactly `@ivar`, and that ivar is assigned in
    # `initialize` exactly from a plain positional parameter (`arg`/`optarg`).
    # Anything else (computed reader, splat/kwarg params, conditional
    # assignment) is skipped — the translation is only sound for a direct bind.
    #
    # The same `@ivar => param_index` bindings are also kept per `initialize`
    # (`Scan#initializers`): `Klass.new(:posts)` holds `:posts` in `@name`
    # wherever `initialize` binds it (felixefelip/steep#205). Whether anything
    # writes the ivar afterwards is the postconditions' `may_write`, not this.
    class ConstructorBindingAnalyzer
      # `readers` as above. `initializers` lists, per class or module, every
      # `initialize` this source defines for it, or nil for one that binds
      # nothing this can read: two, across sources or within one, and which
      # runs is a question of load order. `methods` lists, per class or module,
      # every instance method this source may define for it, as its `Body`
      # when the definition always runs, nil otherwise.
      #
      # `singleton_methods` the same, for the methods defined on the class
      # object itself: `def self.x`, and a `def` in `class << self`.
      #
      # `class_bodies` counts the bodies the source writes for each class or
      # module, under every name the constant may resolve to.
      Scan = Struct.new(:readers, :initializers, :methods, :singleton_methods, :class_bodies, keyword_init: true)

      # One method, as far as the object it runs on goes:
      #
      # - `bindings`: `@ivar => position` for each ivar it assigns straight
      #   from the argument at that call-site position;
      # - `writes`: every ivar it assigns at all;
      # - `super_args`: what its `super` hands on (felixefelip/steep#230). Nil
      #   when it calls none; for each position of the `super` call, the
      #   call-site position of the argument passed there, or nil when that is
      #   not one of this method's arguments as given; `:opaque` when the
      #   `super` may not run, or which arguments land where is not known;
      # - `self_sends`: the methods it calls on `self`;
      # - `exposes_self`: whether `self` may reach anything but those calls,
      #   a block included (felixefelip/steep#205, stage 2);
      # - `returns`: the ivar it returns, when its body is exactly that.
      # - `memo`: `[ivar, class names]` when its body is exactly
      #   `@ivar ||= Klass.new`, with the classes `Klass` may name from where
      #   it is written. Not a `returns`: while the ivar is unset it answers
      #   the new object, not what the ivar held.
      # - `appends`: `@ivar => [[side, value], …]` for each statement of the
      #   body that pushes onto the array an ivar holds (`@rules.prepend(x)`),
      #   in order, `side` being `:front` or `:back` and `value` the argument
      #   position it pushes, or an array of them (`[rule, replacement]`);
      # - `empties`: the ivars a statement of the body sets to `[]`;
      # - `touches`: the ivars it names anywhere else, in a way that may change
      #   the object they hold or hand it on.
      Body = Struct.new(
        :bindings, :writes, :super_args, :self_sends, :exposes_self, :returns, :memo, :appends, :empties, :touches,
        keyword_init: true
      )

      APPENDS = { prepend: :front, unshift: :front, "<<": :back, push: :back }.freeze

      def self.analyze(node)
        scan(node).readers
      end

      def self.scan(node)
        new.scan(node)
      end

      def initialize
        @result = {} #: Hash[String, Hash[Symbol, Integer]]
        @initializers = {} #: Hash[String, Array[Body?]]
        @methods = {} #: Hash[String, Hash[Symbol, Array[Body?]]]
        @singleton_methods = {} #: Hash[String, Hash[Symbol, Array[Body?]]]
        @class_bodies = Hash.new(0) #: Hash[String, Integer]
      end

      def scan(node)
        walk(node, nesting: []) if node.is_a?(::Parser::AST::Node)
        Scan.new(
          readers: @result, initializers: @initializers, methods: @methods, singleton_methods: @singleton_methods, class_bodies: @class_bodies
        )
      end

      private

      def walk(node, nesting:)
        case node.type
        when :class
          const_node, _super, body = node.children
          name = const_to_name(const_node)
          new_nesting = name ? nesting + [name] : nesting
          defined_names(const_node, nesting).each { |defined| @class_bodies[defined] += 1 }
          if body && name
            register_class(body, nesting: new_nesting)
            register_initializers(body, names: defined_names(const_node, nesting))
            register_methods(body, names: defined_names(const_node, nesting))
            register_singleton_methods(body, names: defined_names(const_node, nesting), nesting: new_nesting)
          end
          walk(body, nesting: new_nesting) if body
        when :module
          const_node, body = node.children
          name = const_to_name(const_node)
          new_nesting = name ? nesting + [name] : nesting
          defined_names(const_node, nesting).each { |defined| @class_bodies[defined] += 1 }
          # A module's `initialize` runs for the classes that include it.
          if body && name
            register_initializers(body, names: defined_names(const_node, nesting))
            register_methods(body, names: defined_names(const_node, nesting))
            register_singleton_methods(body, names: defined_names(const_node, nesting), nesting: new_nesting)
          end
          walk(body, nesting: new_nesting) if body
        else
          node.children.each { |c| walk(c, nesting: nesting) if c.is_a?(::Parser::AST::Node) }
        end
      end

      # Collect `@ivar => param_index` from `initialize` and `reader => @ivar`
      # from single-ivar reader defs at this class level, then compose the two
      # into `reader => param_index` entries.
      def register_class(body, nesting:)
        ivar_to_param = {} #: Hash[Symbol, Integer]
        reader_to_ivar = {} #: Hash[Symbol, Symbol]

        each_stmt(body) do |stmt|
          next unless stmt.type == :def
          mname, args, mbody = stmt.children
          if mname == :initialize
            ivar_to_param.merge!(ivar_param_bindings(args, mbody))
          elsif (ivar = single_ivar_reader(mbody))
            reader_to_ivar[mname] = ivar
          end
        end

        entries = {} #: Hash[Symbol, Integer]
        reader_to_ivar.each do |reader, ivar|
          idx = ivar_to_param[ivar]
          entries[reader] = idx if idx
        end
        return if entries.empty?

        key = nesting.join("::")
        (@result[key] ||= {}).merge!(entries)
      end

      # Every `def initialize` in this class body, under each class the
      # constant may name. Where it may name two, which class it builds is not
      # known, and it binds nothing.
      def register_initializers(body, names:)
        each_initialize(body) do |args, mbody|
          initializer = names.size == 1 ? method_body(args, mbody) : nil
          names.each { |name| (@initializers[name] ||= []) << initializer }
        end
      end

      # Every instance method this class body may define, as its `Body` when
      # that is certain. Where the constant may name two classes, which one
      # has the method is not known, so it reads none.
      def register_methods(body, names:)
        each_method_definition(body, direct: true) do |mname, method_body|
          method_body = nil unless names.size == 1
          names.each { |name| ((@methods[name] ||= {})[mname] ||= []) << method_body }
        end
      end

      # Every method this class body may define on the class object, as for
      # `register_methods`.
      def register_singleton_methods(body, names:, nesting:)
        each_singleton_definition(body) do |mname, args, mbody|
          method_body = names.size == 1 ? method_body(args, mbody, nesting: nesting) : nil
          names.each { |name| ((@singleton_methods[name] ||= {})[mname] ||= []) << method_body }
        end
      end

      def each_singleton_definition(body, &block)
        each_stmt(body) do |stmt|
          case stmt.type
          when :defs
            receiver, mname, args, mbody = stmt.children
            yield mname, args, mbody if receiver.type == :self
          when :sclass
            target, sbody = stmt.children
            next unless target.type == :self

            each_stmt(sbody) { |inner| yield(*inner.children) if inner.type == :def }
          end
        end
      end

      # Yields each method name `node` may define on the class whose body it
      # is, with its `Body` when the definition always runs: a `def`, an
      # `attr_*`, as a statement of the body or under a modifier
      # (`private def x = @x`).
      #
      # Anything else that may name a method counts, with no body this reads:
      # an `alias`, `alias_method`, `define_method`, or a definition under a
      # condition, inside a block (`class_eval do`) or inside another method.
      # A nested class, module or singleton body defines elsewhere.
      def each_method_definition(node, direct:, &block)
        return unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :class, :module, :sclass
          nil
        when :begin
          node.children.each { |child| each_method_definition(child, direct: direct, &block) }
        when :def
          mname, args, mbody = node.children
          yield mname, (direct ? method_body(args, mbody) : nil)
          each_method_definition(mbody, direct: false, &block)
        when :alias
          new_name = node.children[0]
          yield new_name.children[0], nil if new_name.type == :sym
        when :send
          receiver, mname, *args = node.children
          if receiver.nil? && %i[private public protected module_function].include?(mname)
            args.each { |arg| each_method_definition(arg, direct: direct, &block) }
          else
            macro_definitions(mname, args, direct: direct).each { |name, body| yield name, body } if receiver.nil?
            node.children.each { |child| each_method_definition(child, direct: false, &block) }
          end
        else
          node.children.each { |child| each_method_definition(child, direct: false, &block) }
        end
      end

      # The methods a receiverless macro call defines, as `[name, body]`
      # pairs, with a body only when the macro always runs.
      def macro_definitions(mname, args, direct:)
        names = args.filter_map { |arg| arg.children[0].to_sym if %i[sym str].include?(arg.type) }
        definitions =
          case mname
          when :alias_method, :define_method
            names.take(1).map { |name| [name, nil] }
          when :attr_reader
            names.map { |name| [name, attr_reader_body(name)] }
          when :attr_accessor
            names.flat_map { |name| [[name, attr_reader_body(name)], [:"#{name}=", attr_writer_body(name)]] }
          when :attr_writer
            names.map { |name| [:"#{name}=", attr_writer_body(name)] }
          else
            []
          end
        direct ? definitions : definitions.map { |name, _| [name, nil] }
      end

      def attr_reader_body(name)
        Body.new(
          bindings: {}, writes: Set[], super_args: nil, self_sends: Set[], exposes_self: false, returns: :"@#{name}",
          appends: {}, empties: Set[], touches: Set[]
        )
      end

      def attr_writer_body(name)
        ivar = :"@#{name}"
        Body.new(
          bindings: { ivar => 0 }, writes: Set[ivar], super_args: nil, self_sends: Set[], exposes_self: false, returns: nil,
          appends: {}, empties: Set[], touches: Set[]
        )
      end

      def method_body(args_node, body, nesting: nil)
        writes = Set[] #: Set[Symbol]
        self_sends = Set[] #: Set[Symbol]
        each_node(body) do |node|
          writes << node.children[0] if node.type == :ivasgn
          self_sends << node.children[1] if %i[send csend].include?(node.type) && (node.children[0].nil? || node.children[0].type == :self)
        end
        appends, empties, touches = collection_effects(args_node, body)
        Body.new(
          appends: appends,
          empties: empties,
          touches: touches,
          bindings: ivar_param_bindings(args_node, body),
          writes: writes,
          super_args: super_args(args_node, body),
          self_sends: self_sends,
          exposes_self: exposes_self?(body),
          returns: single_ivar_reader(body),
          memo: nesting && memo_of(body, nesting)
        )
      end

      # Whether `self` may reach anything but a call made on it: handed on,
      # returned, stored, or captured by a block.
      def exposes_self?(node, parent = nil)
        return false unless node.is_a?(::Parser::AST::Node)
        return true if %i[block numblock].include?(node.type)
        return true if node.type == :self && !(parent && %i[send csend].include?(parent.type) && parent.children[0].equal?(node))

        node.children.any? { |child| exposes_self?(child, node) }
      end

      # Where each argument of this method's `super` comes from, by call-site
      # position. Only a `super` written as a statement of the body itself,
      # the only one in it, in a body that cannot `return` before it: anything
      # else may not run, or may run twice.
      #
      #   def initialize(name, options)
      #     super(options, name)        # => [1, 0]
      #   end
      #
      # A bare `super` passes every parameter where it stands, as it holds
      # at that point: a reassigned one is not the argument it was given.
      def super_args(args_node, body)
        calls = [] #: Array[::Parser::AST::Node]
        each_node(body) { |node| calls << node if node.type == :super || node.type == :zsuper }
        return nil if calls.empty?

        call = calls.first or raise
        return :opaque if calls.size > 1 || contains?(body, :return)
        top_level = false
        each_stmt(body) { |stmt| top_level ||= stmt.equal?(call) }
        return :opaque unless top_level

        reassigned = Set[] #: Set[Symbol]
        each_node(body) { |node| reassigned << node.children[0] if node.type == :lvasgn }
        positions = call_positions(args_node).reject { |name, _| reassigned.include?(name) }

        if call.type == :zsuper
          params = args_node.is_a?(::Parser::AST::Node) ? args_node.children.grep(::Parser::AST::Node) : []
          params.take_while { |param| param.type == :arg || param.type == :optarg }.map { |param| positions[param.children[0]] }
        else
          call.children
            .take_while { |arg| !%i[splat block_pass kwargs forwarded_args forwarded_restarg].include?(arg.type) }
            .map { |arg| arg.type == :lvar ? positions[arg.children[0]] : nil }
        end
      end

      def each_initialize(node, &block)
        return unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :def
          yield node.children[1], node.children[2] if node.children[0] == :initialize
        when :class, :module, :sclass, :defs
          nil
        else
          node.children.each { |child| each_initialize(child, &block) }
        end
      end

      # `@x = param` statements at the top of `initialize`, keyed by ivar,
      # valued by the positional index of `param` at the call. Only for a
      # `param` the body never reassigns, an ivar the body writes once, and an
      # `initialize` that cannot `return` before reaching it: anything else
      # leaves a value that depends on the flow, which this does not read.
      def ivar_param_bindings(args_node, body)
        return {} if contains?(body, :return)

        reassigned = Set[] #: Set[Symbol]
        each_node(body) { |node| reassigned << node.children[0] if node.type == :lvasgn }
        param_index = call_positions(args_node).reject { |name, _| reassigned.include?(name) }
        return {} if param_index.empty?

        writes = Hash.new(0) #: Hash[Symbol, Integer]
        each_node(body) { |node| writes[node.children[0]] += 1 if node.type == :ivasgn }

        result = {} #: Hash[Symbol, Integer]
        each_stmt(body) do |stmt|
          next unless stmt.type == :ivasgn
          ivar, rhs = stmt.children
          next unless rhs.is_a?(::Parser::AST::Node) && rhs.type == :lvar && writes[ivar] == 1
          idx = param_index[rhs.children[0]]
          result[ivar] = idx if idx
        end
        result
      end

      # The parameters whose slot in the list is the argument's position at
      # every call: a required one with no optional before it, an optional one
      # with no required after it, and nothing past a rest. A splat, kwarg or
      # block shifts or breaks positionality.
      #
      #   def initialize(a, b = 1, c)   # only `a`: `P.new(:x, :y)` puts :y in `c`
      def call_positions(args_node)
        params = args_node.is_a?(::Parser::AST::Node) ? args_node.children.grep(::Parser::AST::Node) : []
        positions = {} #: Hash[Symbol, Integer]
        params.each_with_index do |param, index|
          break if param.type == :restarg

          stable =
            case param.type
            when :arg then params.take(index).none? { |other| other.type == :optarg }
            when :optarg then params.drop(index + 1).none? { |other| %i[arg mlhs].include?(other.type) }
            end
          positions[param.children[0]] = index if stable
        end
        positions
      end

      def contains?(node, type)
        each_node(node) { |child| return true if child.type == type }
        false
      end

      def each_node(node, &block)
        return unless node.is_a?(::Parser::AST::Node)

        yield node
        node.children.each { |child| each_node(child, &block) }
      end

      # The classes `class Foo` defines or reopens: unscoped, the one in the
      # current nesting; `class Ex::Foo` inside `module Wrap` names `Foo` in
      # whichever `Ex` resolves from there, `Wrap::Ex` or `::Ex`.
      def defined_names(const_node, nesting)
        name = const_to_name(const_node) or return []
        scope = const_node.children[0]
        return [name] if scope&.type == :cbase || nesting.empty?
        return [[*nesting, name].join("::")] unless scope

        nesting.size.downto(0).map { |depth| [*nesting.take(depth), name].join("::") }
      end

      def collection_effects(args_node, body)
        appends = {} #: Hash[Symbol, Array[[Symbol, untyped]]]
        empties = Set[] #: Set[Symbol]
        counted = {}.compare_by_identity #: Hash[::Parser::AST::Node, bool]
        unless contains?(body, :return)
          positions = stable_positions(args_node, body)
          each_stmt(body) do |stmt|
            if stmt.type == :ivasgn && stmt.children[1]&.type == :array && stmt.children[1].children.empty?
              empties << stmt.children[0]
            elsif (append = append_of(stmt, positions))
              (appends[append[0]] ||= []) << append.drop(1)
              counted[stmt.children[0]] = true
            end
          end
        end

        touches = Set[] #: Set[Symbol]
        each_node(body) { |node| touches << node.children[0] if node.type == :ivar && !counted.key?(node) }
        [appends, empties, touches]
      end

      def append_of(stmt, positions)
        return unless stmt.type == :send

        receiver, method_name, *arguments = stmt.children
        side = APPENDS[method_name]
        return unless side && receiver&.type == :ivar && arguments.size == 1

        value = pushed_value(arguments[0], positions) or return
        [receiver.children[0], side, value]
      end

      # The argument position `node` reads, or an array of them.
      def pushed_value(node, positions)
        case node.type
        when :lvar
          positions[node.children[0]]
        when :array
          values = node.children.map { |element| pushed_value(element, positions) }
          values if values.none?(&:nil?)
        end
      end

      def stable_positions(args_node, body)
        reassigned = Set[] #: Set[Symbol]
        each_node(body) { |node| reassigned << node.children[0] if node.type == :lvasgn }
        call_positions(args_node).reject { |name, _| reassigned.include?(name) }
      end

      def memo_of(body, nesting)
        return unless body&.type == :or_asgn

        target, value = body.children
        return unless target.type == :ivasgn && value.type == :send

        klass, method_name, *arguments = value.children
        return unless method_name == :new && arguments.empty? && klass&.type == :const

        name = const_to_name(klass) or return
        names = klass.children[0]&.type == :cbase ? [name] : nesting.size.downto(0).map { |depth| [*nesting.take(depth), name].join("::") }
        [target.children[0], names]
      end

      # A reader whose body is exactly `@ivar` (normal or endless def) →
      # returns `:@ivar`, else nil.
      def single_ivar_reader(body)
        return nil unless body.is_a?(::Parser::AST::Node)
        body.type == :ivar ? body.children[0] : nil
      end

      def each_stmt(body)
        return unless body.is_a?(::Parser::AST::Node)
        stmts = body.type == :begin || body.type == :kwbegin ? body.children : [body]
        stmts.each { |s| yield s if s.is_a?(::Parser::AST::Node) }
      end

      def const_to_name(node)
        return nil unless node.is_a?(::Parser::AST::Node) && node.type == :const
        scope, name = node.children
        case scope&.type
        when nil, :cbase
          name.to_s
        when :const
          prefix = const_to_name(scope)
          prefix ? "#{prefix}::#{name}" : name.to_s
        end
      end
    end
  end
end
