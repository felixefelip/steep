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

      # `node` checked as the method it defines, or nil where it is not one
      # the class declares, so that it is typed as an ordinary call.
      def check(constr, node)
        module_context = constr.module_context
        return nil if constr.method_context || !module_context
        name, singleton = literal(node)
        return nil unless name
        self_type, definition = singleton ? [module_context.module_type, module_context.module_definition] : [module_context.instance_type, module_context.instance_definition]
        return nil if singleton && !module_context.instance_type.is_a?(AST::Types::Name::Instance)
        return nil unless definition&.methods&.key?(name) && module_define_method?(constr, singleton)

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

      # The parameters of a method, as the block writes them: `|name|` is
      # `(procarg0 :name)`.
      def params_of(args_node)
        args_node.children.map { |param| param.type == :procarg0 ? Parser::AST::Node.new(:arg, param.children, location: param.location) : param }
      end

      private

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
