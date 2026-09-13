module Steep
  module Specializations
    # What one source file contributes to a specialization pass: the methods it
    # defines, and the argument tuples its call sites supply to methods the
    # project defines elsewhere.
    class Collector
      # `{ "Foo#bar" => def node }` for every method defined in `source`.
      def self.definitions(source)
        result = {} #: Hash[String, Parser::AST::Node]
        node = source.node
        walk_defs(node, [], source) { |key, def_node| result[key] = def_node } if node
        result
      end

      # `{ "Foo#bar" => Set[Arguments] }` for the call sites in `typing` that
      # resolve to one method and fix at least one argument to a literal.
      def self.call_sites(typing)
        result = {} #: Hash[String, Set[Arguments]]

        each_call_site(typing) do |key, arguments, _node|
          # A tuple fixing no value specializes nothing: the body would be
          # re-checked under the declaration it already has.
          (result[key] ||= Set.new) << arguments if arguments.literal?
        end

        result
      end

      # The same call sites, with the node each one is, and without the literal
      # filter `call_sites` applies. `call_sites` answers what to specialize; a
      # consumer that has to point back at the source needs to know which call it
      # was, and one that reads a body's control flow needs the calls that fix
      # nothing too.
      def self.each_call_site(typing)
        typing.each_typing do |node, _type|
          next unless node.type == :send

          call = begin
                   typing.call_of(node: node)
                 rescue Typing::UnknownNodeError
                   next
                 end
          next unless call.is_a?(TypeInference::MethodCall::Typed)

          key = Specializations.method_key(call.method_decls) or next
          arguments = Arguments.from_send(node, typing) or next

          yield key, arguments, node
        end
      end

      # The values a definition gives the parameters a call may leave out, by
      # position and by name, for the ones written as a literal. Anything else —
      # a call, a constant, an expression — is left to the declaration, since a
      # default this cannot read is not one it may guess at.
      def self.defaults(def_node)
        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        positionals = {} #: Hash[Integer, AST::Types::t]
        keywords = {} #: Hash[Symbol, AST::Types::t]
        return [positionals, keywords] unless args

        index = 0
        args.children.each do |arg|
          case arg.type
          when :arg, :procarg0
            index += 1
          when :optarg
            type = default_type(arg.children[1])
            positionals[index] = type if type
            index += 1
          when :kwoptarg
            type = default_type(arg.children[1])
            keywords[arg.children[0]] = type if type
          end
        end

        [positionals, keywords]
      end

      def self.default_type(node)
        case node&.type
        when :true then AST::Types::Literal.new(value: true)
        when :false then AST::Types::Literal.new(value: false)
        when :nil then AST::Builtin.nil_type
        when :sym, :str, :int then AST::Types::Literal.new(value: node.children[0])
        end
      end

      # Every project method the call sites in `typing` resolve to, literal
      # argument or not. `call_sites` answers a subset — the calls that fix a
      # value today — and a call that fixes none now may fix one once an inner
      # call specializes, so what file to re-read is decided from this.
      def self.callees(typing)
        result = Set[] #: Set[String]

        typing.each_typing do |node, _type|
          next unless node.type == :send

          call = begin
                   typing.call_of(node: node)
                 rescue Typing::UnknownNodeError
                   next
                 end
          next unless call.is_a?(TypeInference::MethodCall::Typed)

          key = Specializations.method_key(call.method_decls) or next
          result << key
        end

        result
      end

      def self.walk_defs(node, nesting, source, &block)
        return unless node.is_a?(Parser::AST::Node)

        case node.type
        when :class, :module
          name = const_name(node.children[0])
          inner = name ? nesting + [name] : nesting
          body = node.type == :class ? node.children[2] : node.children[1]
          walk_defs(body, inner, source, &block)
        when :block
          walk_block_defs(node, nesting, source, &block)
        when :def
          yield "#{nesting.join("::")}##{node.children[0]}", node unless nesting.empty?
        when :defs
          yield "#{nesting.join("::")}.#{node.children[1]}", node unless nesting.empty?
        when :sclass
          walk_sclass_defs(node, nesting, source, &block)
        else
          node.children.each { |child| walk_defs(child, nesting, source, &block) }
        end
      end

      # A DSL block whose body has a definee of its own — `class_methods do … end`
      # is the one that matters here, and `class_eval` on a stored block is the
      # other. Where the methods land is not where the call is WRITTEN, and
      # `@implements` is what says so; the annotation is injected from the module
      # self-type sidecar, the same fact that gives the body its `self`.
      #
      # Without this a `def` inside `class_methods do` is keyed by the concern
      # that wrote the block, while every call site resolves to the
      # `ClassMethods` the method actually lives on — two names that never meet,
      # so the body is never specialized.
      def self.walk_block_defs(node, nesting, source, &block)
        modules = implemented_modules(source, node)
        if modules.empty?
          node.children.each { |child| walk_defs(child, nesting, source, &block) }
          return
        end

        modules.each do |mod|
          name = mod.name.to_s.delete_prefix("::")

          walk_defs(node.children[2], [name], source) do |key, def_node|
            yield mod.singleton? ? key.sub("#", ".") : key, def_node
          end
        end
      end

      def self.implemented_modules(source, node)
        (source.mapping[node] || []).flat_map do |annotation|
          annotation.is_a?(AST::Annotation::Implements) ? annotation.names : []
        end
      end

      # `class << self` holds singleton methods of the enclosing class, written
      # as plain `def`s. `class << obj` holds singleton methods of that object,
      # which no class name keys.
      def self.walk_sclass_defs(node, nesting, source, &block)
        return unless node.children[0].type == :self

        walk_defs(node.children[1], nesting, source) do |key, def_node|
          yield key.sub("#", "."), def_node
        end
      end

      def self.const_name(node)
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :const

        parent = node.children[0]
        return node.children[1].to_s if parent.nil? || parent.type == :cbase

        prefix = const_name(parent) or return nil
        "#{prefix}::#{node.children[1]}"
      end

      private_class_method :walk_defs, :walk_block_defs, :implemented_modules, :walk_sclass_defs,
                           :const_name, :default_type
    end
  end
end
