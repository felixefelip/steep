module Steep
  # `define_method(:name) { |params| body }` written in a class body defines
  # the method `def name(params) = body` would, and is checked as that method
  # rather than as a block of `Module#define_method`, whose signature gives
  # the block a `self` of `top`. The block is the method's body: its record
  # and its exit are keyed by it, as a `def`'s are by the `def`. Called on
  # `singleton_class`, it defines a method of the class object, as
  # `def self.name` does.
  #
  # A block that reads a local of the class body around it is left a block:
  # its body is not the method's alone.
  module DefinedMethods
    class << self
      # `[name, singleton]` where `node` is that shape: the method's name, and
      # whether it is defined on the class object.
      def literal(node)
        return nil unless node.type == :block

        send_node, params, body = node.children
        receiver, method_name, *arguments = send_node.children
        return nil unless send_node.type == :send && method_name == :define_method && (singleton = singleton_receiver(receiver)) != :other
        return nil unless arguments.size == 1 && %i[sym str].include?(arguments[0].type)
        return nil unless params.children.all? { |param| plain_param?(param) } && closed?(params, body)

        [arguments[0].children[0].to_sym, singleton]
      end

      # `[name, params, body]`, as a `def` node's children are, for a `def`
      # or a `define_method` block on the side `singleton` says.
      def def_parts(node, singleton:)
        return node.children if node.type == :def && !singleton

        name, on_singleton = literal(node)
        [name, node.children[1], node.children[2]] if name && on_singleton == singleton
      end

      # `node` checked as the method it defines, or as the call it is
      # (`yield`) where it is not one the class declares. A block the run
      # found defining a method (`Specializations::HarvestedMethods`) is both:
      # the call, and then, in the frame that wrote it, the method's body.
      def check(constr, node, &call)
        name, singleton = literal(node)
        return harvested_check(constr, node, yield) unless name && constr.module_context && !constr.method_context

        module_context = constr.module_context
        self_type, definition = singleton ? [module_context.module_type, module_context.module_definition] : [module_context.instance_type, module_context.instance_definition]
        return yield if singleton && !module_context.instance_type.is_a?(AST::Types::Name::Instance)
        return yield unless definition&.methods&.key?(name) && module_define_method?(constr, singleton)

        send_node, params, body = node.children
        constr = constr.synthesize(send_node.children[0]).constr if send_node.children[0]
        constr = constr.synthesize(send_node.children[2]).constr
        constr.with_method_constr(name, node, args: params.children, self_type: self_type, definition: definition) do |method_constr|
          method_constr = method_constr.synthesize_children(params)
          ObjectStates.record_exit(method_constr, node, MethodBody.check(method_constr, node, body, setters: false)) if body
        end
        (singleton ? module_context.defined_module_methods : module_context.defined_instance_methods) << name
        constr = constr.add_typing(send_node, type: AST::Builtin::Symbol.instance_type).constr
        constr.add_typing(node, type: AST::Types::Literal.new(value: name))
      end

      # The methods `def_node`'s body defines where it is checked under
      # `arguments`, as `{ key => block }`: a
      # `define_method` on a receiver whose type names a class, with a name
      # that is a literal there, and a block written there or handed in at the
      # call.
      def harvested(typing, def_node, arguments)
        found = {} #: Hash[String, Parser::AST::Node]
        each_define(Specializations::Evals.body_of(def_node)) do |node, send_node|
          block = node.type == :block ? node : handed_block(send_node, def_node, arguments) or next
          name = literal_name(typing, send_node.children[2]) or next
          owner, singleton = definee(typing, send_node.children[0])
          next unless owner
          next unless module_call?(typing, node)

          found["#{owner.to_s.delete_prefix("::")}#{singleton ? "." : "#"}#{name}"] = block
        end
        found
      end

      # The parameters of a method, as the block writes them: `|name|` is
      # `(procarg0 :name)`.
      def params_of(args_node)
        args_node.children.map { |param| param.type == :procarg0 ? Parser::AST::Node.new(:arg, param.children, location: param.location) : param }
      end

      private

      # The method body a found block is, checked after the call it is written
      # at, in the env the call saw: a local it closes over holds what it holds
      # there, unless a block of the same frame assigns it.
      def harvested_check(constr, node, pair)
        return pair unless node.type == :block && (arguments = constr.specialization_arguments(node))

        key = constr.specializations.defined_method([constr.source.path.to_s, node.loc.expression.begin_pos]) or return pair
        owner, name, singleton = parse_key(key)
        builder = constr.checker.factory.definition_builder
        definition = singleton ? builder.build_singleton(owner) : builder.build_instance(owner)
        self_type = arguments.self_type || (singleton ? AST::Types::Name::Singleton.new(name: owner) : constr.checker.factory.instance_type(owner))
        captured = captured_locals(constr, node)
        _send_node, params, body = node.children
        child = constr.with_new_typing(pair.constr.typing.new_child)
        child.with_method_constr(name, node, args: params.children, self_type: self_type, definition: definition) do |method_constr|
          method_constr = method_constr.update_type_env { |env| captured.reduce(env) { |current, (local, type)| current.assign_local_variable(local, type, nil) } }
          method_constr = method_constr.synthesize_children(params)
          ObjectStates.record_exit(method_constr, node, MethodBody.check(method_constr, node, body, setters: false)) if body
        end
        child.typing.save!
        pair
      rescue RBS::BaseError
        pair
      end

      # `"Base.__store"` as `[::Base, :__store, true]`.
      def parse_key(key)
        owner, separator, name = key.rpartition(/[.#]/)
        [RBS::TypeName.parse("::#{owner}"), name.to_sym, separator == "."]
      end

      def captured_locals(constr, node)
        own = Set[]
        read = Set[]
        locals(node.children[1], own, read)
        locals(node.children[2], own, read)
        frame = constr.method_context&.node
        (read - own).to_h do |local|
          type = constr.context.type_env[local] unless frame && assigned_in_block?(frame, local)
          [local, type || AST::Builtin.any_type]
        end
      end

      def assigned_in_block?(node, local, in_block = false)
        return false unless node.is_a?(Parser::AST::Node)
        return true if in_block && node.type == :lvasgn && node.children[0] == local

        inner = in_block || Accumulators::LAMBDA_BODIES.include?(node.type)
        node.children.any? { |child| assigned_in_block?(child, local, inner) }
      end

      def each_define(node, &block)
        return unless node.is_a?(Parser::AST::Node)
        return if %i[def defs class module sclass].include?(node.type)

        send_node = node.type == :block ? node.children[0] : node
        if send_node.type == :send && send_node.children[1] == :define_method && send_node.children[0]
          yield node, send_node if node.type == :block || send_node.children.last&.type == :block_pass
          return if node.type == :block
        end
        node.children.each { |child| each_define(child, &block) }
      end

      def handed_block(send_node, def_node, arguments)
        handed = send_node.children.last
        return nil unless handed.type == :block_pass && handed.children[0]&.type == :lvar

        args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
        param = args.children.find { |arg| arg.type == :blockarg } or return nil
        block = arguments.block
        block if param.children[0] == handed.children[0].children[0] && block.is_a?(Parser::AST::Node) && block.type == :block
      end

      def literal_name(typing, node)
        return nil unless node && typing.has_type?(node)

        type = typing.type_of(node: node)
        type.value.to_sym if type.is_a?(AST::Types::Literal) && (type.value.is_a?(Symbol) || type.value.is_a?(String))
      end

      def definee(typing, receiver)
        return nil unless typing.has_type?(receiver)

        case (type = typing.type_of(node: receiver))
        when AST::Types::MetaClass then [type.name, true]
        when AST::Types::Name::Singleton then [type.name, false]
        end
      end

      # Resolved to `Module#define_method`, whether or not its arguments check:
      # the method that runs does not depend on that.
      def module_call?(typing, node)
        call = typing.call_of(node: node)
        decls = call.is_a?(TypeInference::MethodCall::Typed) || call.is_a?(TypeInference::MethodCall::Error) ? call.method_decls : []
        decls.size == 1 && decls.first.method_name.to_s == "::Module#define_method"
      rescue Typing::UnknownNodeError
        false
      end

      # false for `self` or none, true for `singleton_class` on either,
      # `:other` for any other receiver.
      def singleton_receiver(receiver)
        return false if receiver.nil? || receiver.type == :self
        return :other unless receiver.type == :send && receiver.children[1] == :singleton_class && receiver.children.size == 2

        inner = receiver.children[0]
        inner.nil? || inner.type == :self ? true : :other
      end

      def plain_param?(param)
        return param.children.size == 1 && param.children[0].is_a?(Symbol) if param.type == :procarg0

        %i[arg optarg restarg kwarg kwoptarg kwrestarg blockarg].include?(param.type)
      end

      # Whether every local `body` reads is one of its own.
      def closed?(params, body)
        own = Set[]
        read = Set[]
        locals(params, own, read)
        locals(body, own, read)
        read.subset?(own)
      end

      def locals(node, own, read)
        return unless node.is_a?(Parser::AST::Node)

        case node.type
        when :def, :defs, :class, :module, :sclass
          return
        when :lvar
          read << node.children[0]
        when :procarg0
          own.merge(node.children.grep(Symbol))
        when :lvasgn, :arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg, :shadowarg
          own << node.children[0] if node.children[0]
        end
        node.children.each { |child| locals(child, own, read) }
      end

      # Whether `define_method` called on `self`, or on its singleton class,
      # is `Module`'s.
      def module_define_method?(constr, singleton)
        self_type = constr.self_type
        return false unless self_type.is_a?(AST::Types::Name::Singleton)

        builder = constr.checker.factory.definition_builder
        definition = singleton ? builder.build_instance(RBS::TypeName.parse("::Class")) : builder.build_singleton(self_type.name)
        definition.methods[:define_method]&.defined_in&.to_s == "::Module"
      rescue RBS::BaseError
        false
      end
    end
  end
end
