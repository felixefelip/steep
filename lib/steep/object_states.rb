module Steep
  # Where an `AST::Types::ObjectState` comes from and what it answers
  # (felixefelip/steep#205, stage 1).
  #
  #   reflection = Reflection.new(:posts)   # ::Reflection{@name: :posts}
  #   reflection.name                       # :posts
  #
  # Both are read off the call the checker already typed, against the method it
  # resolved to, and only ever narrow it: the declared return is the bound.
  module ObjectStates
    class << self
      # A `.new` call whose `initialize` fixes an ivar from one of the values it
      # was passed, answering the object with that ivar known. `call` unchanged
      # where nothing is fixed.
      def built(constr, call, arguments:)
        return call unless initialize_call?(call)
        return call unless arguments.all? { |argument| plain_argument?(argument) }

        instance = call.return_type
        return call unless instance.is_a?(AST::Types::Name::Instance)

        bindings = constr.constructor_bindings.immutable_ivar_bindings_for(instance.name.to_s)
        return call if bindings.empty?

        ivars = bindings.filter_map do |ivar, index|
          argument = arguments[index] or next
          next unless constr.typing.has_type?(argument)

          type = constr.literal_operand_type(argument, constr.typing.type_of(node: argument))
          [ivar, type] if fixed?(type)
        end.to_h
        return call if ivars.empty?

        call.with_return_type(AST::Types::ObjectState.new(back_type: instance, ivars: ivars))
      end

      # A reader called on an object whose ivar is known, answering what the
      # object holds. `call` unchanged for any other call.
      def read(constr, call, receiver_type:, arguments:)
        return call unless receiver_type.is_a?(AST::Types::ObjectState) && arguments.empty?

        ivar = constr.attr_method_backing_ivar(call.method_decls) ||
               bound_reader_ivar(constr, receiver_type, call)
        value = ivar && receiver_type.ivar_type(ivar) or return call
        return call unless constr.check_relation(sub_type: value, super_type: call.return_type).success?

        call.with_return_type(value)
      end

      private

      # `Klass.new` resolved to the class's own `initialize`: a `def self.new`
      # answers whatever it likes.
      def initialize_call?(call)
        !call.method_decls.empty? &&
          call.method_decls.all? { |decl| decl.method_def&.member.respond_to?(:name) && decl.method_def.member.name == :initialize }
      end

      # One argument, one position: a splat, keywords or a block pass move what
      # lands where.
      def plain_argument?(argument)
        !%i[splat kwargs block_pass forwarded_args forwarded_restarg].include?(argument.type)
      end

      # A value nothing can change afterwards. A String literal names a value
      # that can (felixefelip/steep#216), and so does an array.
      def fixed?(type)
        case type
        when AST::Types::Literal then !type.value.is_a?(::String)
        when AST::Types::Nil, AST::Types::ObjectState then true
        else false
        end
      end

      # A reader written as `def name = @name` rather than `attr_reader`: the
      # constructor index knows which argument it returns, and so which ivar.
      def bound_reader_ivar(constr, receiver_type, call)
        method_name = call.method_decls.first&.method_name&.method_name or return nil
        class_name = receiver_type.back_type.name.to_s
        index = constr.constructor_bindings.lookup(class_name, method_name) or return nil

        bindings = constr.constructor_bindings.immutable_ivar_bindings_for(class_name)
        matching = bindings.select { |_, bound| bound == index }.keys
        matching.first if matching.size == 1
      end
    end
  end
end
