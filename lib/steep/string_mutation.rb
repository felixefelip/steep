module Steep
  # Which calls leave a String's value as it was (felixefelip/steep#207).
  #
  # A literal type names a value, and a String's value can change in place:
  #
  #     result = word.dup        # "posts"
  #     result.sub!(/s\z/, "")
  #     result                   # "post" — but still typed "posts"
  #
  # So a call on a receiver typed by a String literal is taken to change it,
  # and the receiver widens to `::String` — unless the method is one of the
  # closed list below, each of which reads the string or returns a new one.
  # A list of what is SAFE, not of what mutates: a method this list has never
  # heard of — a newer Ruby's, a project's own — widens, which costs precision
  # and never correctness.
  #
  # Keyed like the intrinsic tables, by the method the call RESOLVED to, and
  # watched by the same registry: a project that redefines one of these has
  # written what the program runs instead, and that entry stops vouching.
  module StringMutation
    ENTRIES = (
      %w[
        -@ [] * % + +@ <=> == === =~ ascii_only? b byteindex byterindex bytes
        bytesize byteslice capitalize casecmp casecmp? center chars chomp chop chr
        codepoints count crypt dedup delete delete_prefix delete_suffix downcase
        dump each_byte each_char each_codepoint each_grapheme_cluster each_line
        empty? encode encoding end_with? eql? freeze getbyte grapheme_clusters gsub
        hash hex include? index inspect intern length lines ljust lstrip match
        match? next oct ord partition reverse rindex rjust rpartition rstrip scan
        scrub size slice split squeeze start_with? strip sub succ sum swapcase to_c
        to_f to_i to_r to_s to_str to_sym tr tr_s undump unicode_normalize
        unicode_normalized? unpack unpack1 upcase upto valid_encoding?
      ].map { |name| "::String##{name}" } +
      %w[< <= > >= between? clamp].map { |name| "::Comparable##{name}" } +
      %w[!~ class clone dup frozen? instance_of? is_a? itself kind_of? nil? object_id respond_to?]
        .map { |name| "::Kernel##{name}" } +
      %w[! != equal? __id__].map { |name| "::BasicObject##{name}" }
    ).to_h { |key| [key, true] }.freeze

    # An in-place method whose effect is computable (felixefelip/steep#209): the
    # value it leaves is what its pure counterpart in `LiteralIntrinsics`
    # answers, and it answers that value where the pattern matched and nil
    # where it did not. Watched like `ENTRIES`, so a project's own `sub!` is
    # not computed through Ruby's `sub`.
    IN_PLACE = { "::String#sub!" => "::String#sub" }.freeze
    MATCH = "::String#match?"

    class << self
      # A call on `receiver`, typed `receiver_type`: the type to dispatch it
      # against, and `constr` with the variable `receiver` reads typed that way
      # from here on. Dispatched against `::String` where the call may change
      # the value, so a `self` return (`sub!`) is not the old value either.
      def widen_receiver(constr, receiver, receiver_type, method_name, private:, block:)
        widened = mutated_type(constr, receiver_type, method_name, private: private, block: block)
        return [receiver_type, constr] unless widened

        [widened, refine(constr, receiver, widened)]
      end

      # `constr` with every String-literal variable that a call inside `node`
      # may change widened to `::String` — for a block or a loop body, entered
      # with the outer locals pinned, so nothing narrowed there comes back out.
      # It may run any number of times, so the body itself sees the changed
      # value from its second pass on. `shadowed` are the names a block
      # parameter rebinds, which are not the outer variable.
      def widen_mutated_in(constr, node, shadowed: Set[])
        each_variable_call(node, shadowed) do |receiver, method_name, block|
          type = constr.context.type_env[receiver.children[0]] or next
          widened = mutated_type(constr, type, method_name, private: false, block: block) or next

          constr = refine(constr, receiver, widened)
        end

        constr
      end

      # The names a block's parameter list binds, block-local ones (`|x; y|`)
      # included. A numbered or `it` block binds none an outer local could share.
      def block_parameter_names(params)
        return Set[] unless params.is_a?(Parser::AST::Node)

        params.children.each_with_object(Set[]) do |child, names|
          case child
          when Symbol
            names << child
          when Parser::AST::Node
            case child.type
            when :arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg, :shadowarg
              names << child.children[0] if child.children[0]
            else
              names.merge(block_parameter_names(child))
            end
          end
        end
      end

      # The type `type` is once the value it names may have changed: each
      # String literal in it as `::String`. The same object where there is none.
      def widen(type)
        case type
        when AST::Types::Literal
          type.value.is_a?(::String) ? AST::Builtin::String.instance_type : type
        when AST::Types::Union, AST::Types::Intersection
          types = type.types.map { |member| widen(member) }
          return type if types.zip(type.types).all? { |widened, member| widened.equal?(member) }

          type.is_a?(AST::Types::Union) ? AST::Types::Union.build(types: types) : AST::Types::Intersection.build(types: types)
        else
          type
        end
      end

      # Whether a call through `keys` — every method it may resolve to — leaves
      # the receiver's value as it was. A call with a block never does: the
      # block can reach the receiver through a name it closes over.
      def preserves?(keys, block:, override_registry:)
        return false if block || keys.empty?

        keys.all? { |key| ENTRIES.key?(key) && !override_registry.blocked?(key) }
      end

      # After an in-place call on a single String literal that was dispatched
      # against `::String`: the value it leaves, where every operand is a
      # literal — the variable typed by it, and the call answering it or nil.
      # `type` and `constr` unchanged where that cannot be computed, which
      # leaves the widening `widen_receiver` already made.
      def fold_in_place(constr, node, receiver, receiver_type, method_name, arguments, type:, private:)
        return [type, constr] unless receiver_type.is_a?(AST::Types::Literal) && receiver_type.value.is_a?(::String)

        keys = string_method_keys(constr, method_name, private: private)
        return [type, constr] unless keys.size == 1 && (pure = IN_PLACE[keys.first])

        registry = constr.literal_method_registry
        return [type, constr] if registry.blocked?(keys.first)

        argument_types = arguments.map do |argument|
          return [type, constr] unless constr.typing.has_type?(argument)

          constr.literal_operand_type(argument, constr.typing.type_of(node: argument))
        end

        value = LiteralIntrinsics.fold_key(key: pure, receiver_type: receiver_type, argument_types: argument_types, override_registry: registry)
        matched = LiteralIntrinsics.fold_key(key: MATCH, receiver_type: receiver_type, argument_types: argument_types.take(1), override_registry: registry)
        return [type, constr] unless value && matched.is_a?(AST::Types::Literal)

        returned = matched.value ? value : AST::Builtin.nil_type
        return [type, constr] unless constr.check_relation(sub_type: returned, super_type: type).success?

        constr = refine(constr, receiver, value)
        [returned, constr.add_typing(node, type: returned).constr]
      end

      def watched_keys
        @watched_keys ||= Set.new(ENTRIES.keys + IN_PLACE.keys)
      end

      def method_keys_for(class_name)
        prefix = "::#{class_name}#"
        watched_keys.select { |key| key.start_with?(prefix) }
      end

      private

      # `type` widened, where the call may change the value it names; nil where
      # it leaves the value as it was, or there is no literal to widen.
      def mutated_type(constr, type, method_name, private:, block:)
        widened = widen(type)
        return if widened.equal?(type)

        keys = string_method_keys(constr, method_name, private: private)
        return if preserves?(keys, block: block, override_registry: constr.literal_method_registry)

        widened
      end

      # The methods a call by `method_name` on a String resolves to, keyed as the
      # intrinsic tables are. Empty for one String does not have: nothing vouches
      # for it.
      def string_method_keys(constr, method_name, private:)
        interface = constr.calculate_interface(AST::Builtin::String.instance_type, private: private) or return []
        method = interface.methods[method_name] or return []

        method.overloads
          .flat_map { |overload| overload.method_decls(method_name) }
          .map { |decl| MethodIdentity.normalize(decl.method_name.to_s) }
          .uniq
      end

      # Only a local and an ivar name the value itself; any other receiver is a
      # value this call is the last to see.
      def refine(constr, receiver, type)
        case receiver.type
        when :lvar
          name = receiver.children[0] #: Symbol
          constr.update_type_env { |env| env.refine_types(local_variable_types: { name => type }) }
        when :ivar
          name = receiver.children[0] #: Symbol
          constr.update_type_env { |env| env.refine_types(instance_variable_types: { name => type }) }
        else
          constr
        end
      end

      # Each call in `node` made on a local or an ivar, with whether it passes a
      # block. A nested block rebinds its own parameters; a `def`, a class or a
      # module opens a scope the outer locals do not reach.
      def each_variable_call(node, shadowed, &block)
        return unless node.is_a?(Parser::AST::Node)

        case node.type
        when :def, :defs, :class, :module, :sclass
          return
        when :block, :numblock, :itblock
          send_node, params, body = node.children
          yield_variable_call(send_node, shadowed, block: true, &block)
          send_node.children.each { |child| each_variable_call(child, shadowed, &block) }
          each_variable_call(body, shadowed + block_parameter_names(params), &block)
          return
        when :send, :csend
          yield_variable_call(node, shadowed, block: false, &block)
        end

        node.children.each { |child| each_variable_call(child, shadowed, &block) }
      end

      def yield_variable_call(node, shadowed, block:)
        return unless node.type == :send || node.type == :csend

        receiver, method_name = node.children
        return unless receiver.is_a?(Parser::AST::Node)

        case receiver.type
        when :lvar
          yield receiver, method_name, block unless shadowed.include?(receiver.children[0])
        when :ivar
          yield receiver, method_name, block
        end
      end
    end
  end
end
