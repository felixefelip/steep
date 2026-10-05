module Steep
  module Contracts
    # Resolves, within a single method body, which `local.attr` reads project a
    # self-rooted path — so a deref through the local (`record.post.user`) can be
    # rooted at `self` (`self.owner.user`) for precondition inference and
    # narrowing (felixefelip/steep#62). Two sources of `local.attr => path`:
    #
    #   1. a direct write `local.attr = <self path>` (`record.post = owner`);
    #   2. `local = <self-call>` where the callee return-aliases a reader to a
    #      self path (`record = build`, with `build` returning a record whose
    #      `post` is `self.owner`).
    #
    # And, separately, which locals ARE a self path (`local_aliases`):
    #
    #   3. `local = <self path>` (`_ = user`) — so `_.full_name` is
    #      `self.user.full_name`. ActiveSupport's `delegate` writes exactly
    #      this: `_ = user; _.email(...)`.
    #
    # Purely syntactic; paths are arrays of method symbols (`self.owner` → [:owner]).
    module AliasResolver
      module_function

      # `self.a.b.c` → [:a, :b, :c]; nil unless `node` is a pure self-rooted
      # send chain (no args, rooted at `self` or implicit self).
      def self_path(node)
        return nil unless node.is_a?(::Parser::AST::Node) && node.type == :send
        methods = [] #: Array[Symbol]
        current = node #: Parser::AST::Node?
        while current.is_a?(::Parser::AST::Node) && current.type == :send
          recv, mname, *args = current.children
          return nil unless args.empty?
          methods.unshift(mname)
          current = recv
        end
        return nil unless current.nil? || (current.is_a?(::Parser::AST::Node) && current.type == :self)
        methods
      end

      # Like `self_path`, but rooting through a local-attr alias: resolve a
      # send-chain node to the self path it denotes given `aliases`
      # (`record.post.user` with `[record, post] => [:owner]` → [:owner, :user]).
      # Returns [path_syms] or nil when the chain is not self-rooted (directly or
      # via an alias). felixefelip/steep#64.
      def resolve_self_path(node, aliases, locals = {})
        return nil unless node.is_a?(::Parser::AST::Node) && node.type == :send
        methods = [] #: Array[Symbol]
        current = node #: Parser::AST::Node?
        while current.is_a?(::Parser::AST::Node) && current.type == :send
          recv, mname, *args = current.children
          return nil unless args.empty?
          if recv.is_a?(::Parser::AST::Node) && recv.type == :lvar && (path = aliases[[recv.children[0], mname]])
            return path + methods
          end
          methods.unshift(mname)
          current = recv
        end
        if (path = local_path(current, locals))
          return path + methods
        end
        return nil unless current.nil? || (current.is_a?(::Parser::AST::Node) && current.type == :self)
        methods
      end

      # The self path a local read denotes, per `local_aliases`; nil for any
      # other node, and for a read written before the assignment.
      def local_path(node, locals)
        return nil unless node.is_a?(::Parser::AST::Node) && node.type == :lvar

        local = locals[node.children[0]] or return nil
        position = node.location&.expression&.begin_pos
        return nil unless position && position >= local.fetch(:after)

        local.fetch(:path)
      end

      # `foo` / `self.foo` (no args) → :foo; nil otherwise.
      def self_call_method(node)
        return nil unless node.is_a?(::Parser::AST::Node) && node.type == :send
        recv, mname, *args = node.children
        return nil unless args.empty?
        return nil unless recv.nil? || (recv.is_a?(::Parser::AST::Node) && recv.type == :self)
        mname
      end

      # { [local_sym, attr_sym] => [path_syms] } for a method body. `class_name`
      # + `return_aliases` ("Class#method" => { reader => path }) drive the
      # `local = <self-call>` case; pass an empty hash to consider only direct
      # `local.attr = <self path>` writes.
      def local_attr_aliases(body, class_name:, return_aliases:)
        aliases = {} #: Hash[[Symbol, Symbol], Array[Symbol]]
        walk(body) do |node|
          case node.type
          when :send
            recv, mname, *args = node.children
            next unless recv.is_a?(::Parser::AST::Node) && recv.type == :lvar
            next unless mname.to_s.end_with?("=") && args.size == 1
            path = self_path(args[0])
            next unless path
            aliases[[recv.children[0], mname.to_s.delete_suffix("=").to_sym]] = path
          when :lvasgn
            local, rhs = node.children
            method = self_call_method(rhs)
            next unless method
            readers = return_aliases["#{class_name}##{method}"]
            next unless readers
            readers.each { |reader, path| aliases[[local, reader]] = path }
          end
        end
        aliases
      end

      # { local_sym => { path: [path_syms], after: offset } } for a method body:
      # the locals assigned a self path (`_ = user`, `_ = post.user`), read as
      # that path from the end of the assignment on.
      #
      # Only where the local IS that path wherever it is read after it:
      #
      # - it is assigned once in the body — two writes, and which one a read
      #   sees is a question of flow this does not ask;
      # - no parameter of the body has its name — a block's `|_|` is another
      #   variable inside the block;
      # - the body never writes the path's first reader (`self.user = …`) — the
      #   local holds the value at the assignment, and a precondition is about
      #   the value on entry.
      def local_aliases(body)
        writes = Hash.new { |hash, name| hash[name] = [] } #: Hash[Symbol, Array[Parser::AST::Node]]
        parameters = Set[] #: Set[Symbol]
        written_readers = Set[] #: Set[Symbol]

        walk(body) do |node|
          case node.type
          when :lvasgn
            writes[node.children[0]] << node
          when :arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg, :shadowarg, :procarg0
            name = node.children[0]
            parameters << name if name.is_a?(Symbol)
          when :send
            recv, mname, = node.children
            if (recv.nil? || recv.type == :self) && mname.to_s.end_with?("=") && mname != :==
              written_readers << mname.to_s.delete_suffix("=").to_sym
            end
          end
        end

        locals = {} #: Hash[Symbol, { path: Array[Symbol], after: Integer }]
        writes.each do |name, assignments|
          next unless assignments.size == 1
          next if parameters.include?(name)

          assignment = assignments.first
          path = self_path(assignment.children[1]) or next
          next if written_readers.include?(path.first)

          locals[name] = { path: path, after: assignment.location.expression.end_pos }
        end
        locals
      end

      def walk(node, &block)
        return unless node.is_a?(::Parser::AST::Node)
        yield node
        node.children.each { |c| walk(c, &block) }
      end
    end
  end
end
