module Steep
  module ReflectionIntrinsics
    # The constant table as `Module#const_get` and `Module#const_set` read it,
    # for the signatures an environment declares.
    module Constants
      class << self
        # `Module#const_get` of a literal name, typed as the checker types the
        # same name written `Receiver::Name`, plus what `const_get` adds to that:
        # the toplevel for the first segment, a `"A::B"` or `"::A"` path, and
        # `inherit: false`. A name the signatures do not declare declines rather
        # than reports: code the checker cannot see may define it.
        def constant_named(receiver, argument_types, factory)
          return nil unless receiver.is_a?(AST::Types::Name::Singleton)

          name, inherit_type = argument_types
          return nil unless argument_types.size.between?(1, 2) && name.is_a?(AST::Types::Literal)

          inherit = inherit_type ? literal_truthiness(inherit_type) : true
          path = constant_path(receiver.name, name.value) or return nil
          owner, segments = path

          type = nil #: AST::Types::t?
          segments.each_with_index do |segment, index|
            return nil if type && !type.is_a?(AST::Types::Name::Singleton)

            owner = type.name if type.is_a?(AST::Types::Name::Singleton)
            constant = child_constant(owner, segment, inherit, factory, toplevel: index.zero?) or return nil
            type = factory.type(constant.type)
          end
          type
        end

        # `[module the lookup starts at, segments]`, or nil for a name Ruby
        # rejects with `NameError`. A Symbol is one constant name; only a String
        # is a path.
        def constant_path(receiver_name, value)
          case value
          when ::Symbol
            segments = [value]
          when ::String
            receiver_name = RBS::BuiltinNames::Object.name if value.start_with?("::")
            segments = value.delete_prefix("::").split("::", -1).map(&:to_sym)
          else
            return nil
          end
          return nil unless segments.all? { |segment| segment.match?(/\A[A-Z]\w*\z/) }

          [receiver_name, segments]
        end

        # `:unknown` for an `inherit` that is no literal, which still has an
        # answer wherever the module's own table has one.
        def literal_truthiness(type)
          case type
          when AST::Types::Literal then type.value ? true : false
          when AST::Types::Nil then false
          else :unknown
          end
        end

        def child_constant(owner, name, inherit, factory, toplevel:)
          resolver = factory.constant_resolver
          owner = factory.env.normalize_module_name(owner)
          own = resolver.table.children(owner)&.[](name)
          return own if own || inherit != true

          found = resolver.resolve_child(owner, name)
          return found if found || !toplevel || !reaches_toplevel?(owner, factory)

          resolver.table.toplevel[name] || resolver.resolve_child(RBS::BuiltinNames::Object.name, name)
        end

        # Ruby falls back to `Object` for a module, and a class reaches it as an
        # ancestor; a `BasicObject` subclass does neither.
        def reaches_toplevel?(owner, factory)
          return true if factory.env.class_decls[owner].is_a?(RBS::Environment::ModuleEntry)

          factory.definition_builder.ancestor_builder.instance_ancestors(owner).ancestors.any? do |ancestor|
            ancestor.name == RBS::BuiltinNames::Object.name
          end
        end

        def declared_as?(constant, value, factory)
          value = ObjectStates.state_in(value)&.back_type || value
          return false unless value.is_a?(AST::Types::Name::Instance)

          entry = factory.env.class_decls[constant]
          case value.name
          when RBS::BuiltinNames::Module.name then entry.is_a?(RBS::Environment::ModuleEntry)
          when RBS::BuiltinNames::Class.name then entry.is_a?(RBS::Environment::ClassEntry)
          else false
          end
        end
      end
    end
  end
end
