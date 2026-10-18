module Steep
  module ObjectStates
    # The ivars of an instance `self` a body reaches only through calls made
    # on them (`TypeInference::HeldIvars`), whose objects it follows as it
    # follows a local's (felixefelip/steep#312).
    module HeldIvar
      class << self
        # The ivar of `self` `node` reads: `@ivar`, or a reader of it called
        # on `self` with no arguments.
        def self_ivar(constr, node)
          case node.type
          when :ivar then node.children[0]
          when :send then reader_ivar(constr, constr.self_type, node.children[1]) if node.children.size == 2 && ObjectStates.on_self?(node)
          end
        end

        # The variable `node` reads: a local, or an ivar of `self`.
        def variable(constr, node)
          node.type == :lvar ? node.children[0] : self_ivar(constr, node)
        end

        def refine_variable(constr, node, type)
          node.type == :lvar ? ObjectStates.refine_local(constr, node.children[0], type) : refine(constr, self_ivar(constr, node), type)
        end

        def held?(constr, ivar)
          held_ivars(constr)&.held?(ivar) || false
        end

        def held_ivars(constr)
          constr.method_context&.held_ivars { |name| reader_ivar(constr, constr.self_type, name) }
        end

        # The ivar `name`, called with no arguments on `instance`, an
        # instance `self`, answers: an `attr_reader`'s, or a method whose body
        # is the ivar.
        def reader_ivar(constr, instance, name)
          return unless instance.is_a?(AST::Types::Name::Instance)

          method = constr.checker.factory.definition_builder.build_instance(instance.name).methods[name] or return
          members = method.defs.map(&:member)
          if members.all? { |member| member.is_a?(RBS::AST::Members::AttrReader) || member.is_a?(RBS::AST::Members::AttrAccessor) }
            ivars = members.map { |member| member.ivar_name == false ? nil : member.ivar_name || :"@#{member.name}" }.uniq
            return ivars.first if ivars.size == 1
          end
          ObjectStates.resolved_body(constr, instance, name)&.last&.returns
        rescue RBS::BaseError
          nil
        end

        # A call on `self`, or one handed `self`, leaves the objects `self`'s
        # ivars hold here, but the ones the body was entered with
        # (`ObjectStates.self_moved`), as that call's own check left them, or
        # with what holds under any name.
        def moved(constr, exit)
          return constr unless constr.self_type.is_a?(AST::Types::Name::Instance)

          def_node = constr.method_context&.node
          entered = def_node && constr.specialization_arguments(def_node)&.self_ivars || {}
          env = constr.context.type_env
          held = ObjectStates.self_ivars(constr).keys - entered.keys
          left = ObjectStates.moved_ivars(constr, constr.self_type, held.to_h { |ivar| [ivar, env[ivar]] }, exit)
          moved = held.to_h { |ivar| [ivar, left.fetch(ivar) { ObjectStates.settled(constr, env[ivar]) }] }
          moved.empty? ? constr : constr.update_type_env { |current| current.refine_types(instance_variable_types: moved) }
        end

        # `ObjectStates.refine_local` for an ivar of `self`. What a call on
        # `self` answered may have been read off it, so none cached holds.
        def refine(constr, ivar, type)
          return constr if constr.context.type_env[ivar] == type

          constr.update_type_env do |env|
            self_calls = env.pure_method_calls.keys.select { |node| ObjectStates.on_self?(node) }
            env = self_calls.reduce(env.invalidate_pure_node(::Parser::AST::Node.new(:ivar, [ivar]))) { |current, node| current.invalidate_pure_node(node) }
            env.invalidate_self_pure_calls.refine_types(instance_variable_types: { ivar => type })
          end
        end
      end
    end
  end
end
