module Steep
  module ObjectStates
    # A hash's own method that stores under its key what it holds nothing
    # under yet (felixefelip/steep#354), the keyed form of `@ivar ||= value`:
    #
    #   class Fallbacks < Hash
    #     def [](locale) = super || store(locale, compute(locale))
    #   end
    #
    # The hash only ever holds `compute(locale)` under `locale`, so the call
    # answers that whether the key was filled or not, and reads the object.
    # Only where what the value reads is settled once the object is built
    # (its ivars, written only while it is built, and nothing outside it,
    # `Body#outside_state`), no method the memo runs writes the entries, and
    # every object of the class is one a memo `@ivar ||= Klass.new` the
    # project follows built (`ClassMemos.tracked`).
    module KeyedMemo
      class << self
        # The memo's read of its own entries adds nothing to its value, so
        # it answers `nil` and the call answers what the memo stores.
        def answered(constr, call, node)
          call.with_return_type(AST::Builtin.nil_type) if read_type(constr, node)
        end

        # `nil` for the memo's read, `self[key]` or a bare `super`.
        def read_type(constr, node)
          def_node = constr.method_context&.node
          instance = constr.self_type
          return unless def_node && instance.is_a?(AST::Types::Name::Instance) && memo_read?(def_node, node)

          AST::Builtin.nil_type if kept?(constr, instance, constr.method_context.name)
        end

        # `store` answers the value it stores.
        def stored(constr, call, arguments)
          return unless call.is_a?(TypeInference::MethodCall::Typed) && arguments.size == 2 && constr.typing.has_type?(arguments[1])

          names = call.method_decls.map { |decl| decl.method_name.to_s }.uniq
          return unless names == ["::Hash#store"]

          value = constr.typing.type_of(node: arguments[1])
          call.with_return_type(value) if constr.check_relation(sub_type: value, super_type: call.return_type).success?
        end

        # A call of the memo reads its object.
        def effect(constr, instance, body)
          Effect.new(bindings: {}, writes: Set[], reads_only: true, reader: nil) if read?(constr, instance, body)
        end

        def kept?(constr, instance, method_name)
          _, body = ObjectStates.resolved_body(constr, instance, method_name)
          !!body&.keyed_memo && read?(constr, instance, body) && built_by_memos?(constr, instance)
        end

        private

        def writers = TypeInference::ConstructorBindingAnalyzer::HandedBack::ENTRY_WRITERS

        def memo_read?(def_node, node)
          body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
          tail = body&.type == :begin ? body.children.last : body
          tail&.type == :or && tail.children[0].equal?(node)
        end

        def read?(constr, instance, body)
          body.writes.empty? && entries_left?(constr, instance, body.self_sends - [:store], Set[]) && settled?(constr, instance, body.keyed_memo)
        end

        # No method of `names`, or one they call on `self`, writes the entries.
        def entries_left?(constr, instance, names, visiting)
          names.all? do |name|
            next true if visiting.include?(name)
            next false if writers.include?(name)

            _, callee = ObjectStates.resolved_body(constr, instance, name)
            next !constr.constructor_bindings.defines_any?([name]) unless callee

            entries_left?(constr, instance, callee.self_sends, visiting | [name])
          end
        end

        # Every `Klass.new` is the one of a memo the project follows.
        def built_by_memos?(constr, instance)
          calls = %i[new allocate].flat_map { |name| constr.constructor_bindings.calls_of(name) }.select { |call| builds?(constr, call, instance) }
          !calls.empty? && calls.all? do |call|
            next false if call.kind == :escape || call.called != :new || call.at.nil? || call.enclosing.nil? || call.owner.to_s.empty?

            owner = AST::Types::Name::Singleton.new(name: RBS::TypeName.parse("::#{call.owner}"))
            ClassMemos.tracked(constr, owner, call.enclosing, instance)
          end
        end

        # Whether a call of `new` may build an object of `instance`'s class:
        # one of a class that descends from it, made on it or, bare, in it.
        def builds?(constr, call, instance)
          return true if call.kind == :escape

          classes =
            if call.at
              type = constr.specializations.receiver_type(call.at, factory: constr.checker.factory) or return true
              (type.is_a?(AST::Types::Union) ? type.types : [type]).map { |member| member.is_a?(AST::Types::Name::Singleton) ? member.name : (return true) }
            else
              return true if call.owner.to_s.empty?

              [RBS::TypeName.parse("::#{call.owner}")]
            end
          classes.any? { |name| descends?(constr, name, instance.name) }
        end

        def descends?(constr, name, ancestor)
          constr.checker.factory.definition_builder.build_instance(name).ancestors.ancestors.any? { |each| each.name == ancestor }
        rescue RBS::BaseError
          true
        end

        # What `value` reads stays as it was once the object is built.
        def settled?(constr, instance, value)
          ivars = Set[] #: Set[Symbol]
          return false unless reads_settled?(constr, instance, value, ivars, Set[])

          building = building_methods(constr, instance)
          ivars.all? { |ivar| written_while_built?(constr, instance, ivar, building) }
        end

        def reads_settled?(constr, instance, node, ivars, visiting)
          return true unless node.is_a?(::Parser::AST::Node)
          return false if TypeInference::ConstructorBindingAnalyzer::OUTSIDE.include?(node.type) || node.type == :const
          return false if node.type == :send && node.children[1] == :class && node.children[0]&.type == :self

          ivars << node.children[0] if node.type == :ivar
          if node.type == :send && (node.children[0].nil? || node.children[0].type == :self)
            return false unless method_settled?(constr, instance, node.children[1], ivars, visiting)
          end
          node.children.all? { |child| reads_settled?(constr, instance, child, ivars, visiting) }
        end

        def method_settled?(constr, instance, method_name, ivars, visiting)
          return true if visiting.include?(method_name)

          _, body = ObjectStates.resolved_body(constr, instance, method_name)
          return false if body.nil? || body.outside_state || body.super_args || body.self_sends.intersect?(writers)

          ivars.merge(body.ivars || [])
          ivars << body.returns if body.returns
          body.self_sends.all? { |name| method_settled?(constr, instance, name, ivars, visiting | [method_name]) }
        end

        # `initialize`, and each method only ever called on `self` while one
        # of these runs.
        def building_methods(constr, instance)
          building = Set[:initialize]
          names = constr.constructor_bindings.keyed_memo_names - %i[new allocate]
          loop do
            grown = names.select do |name|
              !building.include?(name) &&
                Specializations::Receivers.calls_on(constr, name, instance).all? { |call| call.kind != :escape && call.at.nil? && building.include?(call.enclosing) }
            end
            return building if grown.empty?

            building.merge(grown)
          end
        end

        def written_while_built?(constr, instance, ivar, building)
          definition = constr.checker.factory.definition_builder.build_instance(instance.name)
          definition.ancestors.ancestors.all? do |ancestor|
            constr.constructor_bindings.method_bodies(ancestor.name.to_s).all? do |name, bodies|
              building.include?(name) || bodies.all? { |body| body && !body.writes.include?(ivar) && reads_only?(constr, instance, ivar, body, name) }
            end
          end
        rescue RBS::BaseError
          false
        end

        # Values no call can change, however they are used.
        UNCHANGEABLE = %w[::Symbol ::Integer ::Float ::NilClass ::TrueClass ::FalseClass].freeze

        def unchangeable?(type)
          return type.types.all? { |member| unchangeable?(member) } if type.is_a?(AST::Types::Union)

          ObjectStates.fixed?(type) || (type.is_a?(AST::Types::Name::Instance) && UNCHANGEABLE.include?(type.name.to_s))
        end

        def reads_only?(constr, instance, ivar, body, name)
          uses = body.ivar_uses[ivar] or return true
          held = Nested.declared_ivar_type(constr, instance, ivar)
          (held && unchangeable?(held)) || Nested.reads_ivar?(constr, instance, ivar, uses, [[instance, name]])
        end
      end
    end
  end
end
