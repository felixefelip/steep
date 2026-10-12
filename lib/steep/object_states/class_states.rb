module Steep
  module ObjectStates
    # What a class body leaves its class object holding, for the code that runs
    # after it (felixefelip/steep#246):
    #
    #   class Inflector
    #     def self.rules = @rules ||= Rules.new
    #     rules.singular(/s\z/, "")      # Inflector{@rules: Rules{@singulars: [[/s\z/, ""]]}}
    #   end
    #
    #   class Model
    #     has_many_like :posts           # checked under that state
    #   end
    #
    # A class ivar keeps its state only while no method of the class may
    # rewrite it (`rewritable?`); a memo `ClassMemos` follows already knows its
    # one writer. A method runs whenever it is called, so it is entered with
    # the states its call site knew (`of_call`), not the ones around its
    # definition.
    module ClassStates
      class << self
        # A `class`/`module` body entered from `outer`, knowing what `outer`
        # knew of other classes. Its own state is `self`'s ivars there.
        def entered(constr, outer)
          states = outer.context.type_env.class_states
          states = states.except(constr.self_type.name) if constr.self_type.is_a?(AST::Types::Name::Singleton)
          constr = constr.update_type_env { |env| env.update(class_states: states) } unless states.empty?
          ClassMemos.entered_class(constr)
        end

        # `outer` once a body that ended as `exit` has run.
        def left(outer, exit)
          return outer unless exit

          states = exit.context.type_env.class_states
          singleton = exit.self_type
          if singleton.is_a?(AST::Types::Name::Singleton)
            ivars = held(exit, singleton)
            states = ivars.empty? ? states.except(singleton.name) : states.merge(singleton.name => ivars)
          end
          outer.update_type_env { |env| env.update(class_states: states) }
        end

        # The class states a call hands its callee: its receiver's, and those of
        # the classes its body, or a method it calls on `self`, names.
        def of_call(constr, call)
          known = constr.context.type_env.class_states
          singleton = constr.self_type
          if singleton.is_a?(AST::Types::Name::Singleton) && !(own = held(constr, singleton)).empty?
            known = known.merge(singleton.name => own)
          end
          return known if known.empty?

          receiver = call.is_a?(TypeInference::MethodCall::Typed) ? call.receiver_type : nil
          names = named_classes(constr, call)
          known.select do |name, _|
            (receiver.is_a?(AST::Types::Name::Singleton) && receiver.name == name) || names.include?(name.to_s.delete_prefix("::"))
          end
        end

        # The method body `arguments` keys, entered with the class states its
        # caller knew.
        def entered_method(env, arguments)
          return env unless arguments

          env.refine_types(instance_variable_types: arguments.self_ivars).update(class_states: arguments.class_states)
        end

        # The ivars of a class object whose state a call may carry: none a
        # method of the class may rewrite.
        def carried(constr, ivars)
          singleton = constr.self_type
          return ivars unless singleton.is_a?(AST::Types::Name::Singleton) && !ivars.empty?

          ivars.reject { |ivar, _| rewritable?(constr, singleton.name, ivar) }
        end

        # A call made in a class body may reach a method that rewrites one of
        # the class's ivars, by whatever path: those it held are known no
        # longer.
        def after_call(constr)
          singleton = constr.self_type
          return constr unless singleton.is_a?(AST::Types::Name::Singleton) && !constr.method_context

          env = constr.context.type_env
          stale = env.instance_variable_types.keys.select do |ivar|
            ObjectStates.state_in(env[ivar]) && rewritable?(constr, singleton.name, ivar)
          end
          return constr if stale.empty?

          constr.update_type_env do |current|
            current.refine_types(instance_variable_types: stale.to_h { |ivar| [ivar, ObjectStates.declared_ivar(constr, ivar)] })
          end
        end

        # What a call's body may reach on its receiver, following the calls it
        # makes on `self`: the ivars it names, and whether it observes which
        # class it runs on — by handing `self` on, or by calling on it a method
        # the project does not write (`const_set`, `name`).
        Reach = Struct.new(:ivars, :observes_self)

        # Each method is the one the receiver's ancestry runs (`resolved_body`).
        def reach(constr, call)
          reach = Reach.new(Set[], false)
          return reach unless call.is_a?(TypeInference::MethodCall::Typed)

          receiver = call.receiver_type
          receiver = constr.self_type if receiver.is_a?(AST::Types::Self)
          return reach unless receiver.is_a?(AST::Types::Name::Singleton) || receiver.is_a?(AST::Types::Name::Instance)

          _, body = ObjectStates.resolved_body(constr, receiver, call.method_name)
          visit_reach(constr, receiver, body, reach, Set[call.method_name]) if body
          reach
        end

        private

        def visit_reach(constr, receiver, body, reach, seen)
          reach.ivars.merge(body.ivars || []).merge(body.writes).merge([body.returns].compact)
          reach.observes_self ||= body.exposes_self
          body.self_sends.each do |sent|
            next unless seen.add?(sent)

            _, callee = ObjectStates.resolved_body(constr, receiver, sent)
            callee ? visit_reach(constr, receiver, callee, reach, seen) : reach.observes_self = true
          end
        end

        # `self`'s ivars a body leaves known: its memos' objects as they stand,
        # any other with what holds under any name.
        def held(constr, singleton)
          memos = memo_ivars(constr, singleton.name)
          ObjectStates.self_ivars(constr).filter_map do |ivar, type|
            value = memos.include?(ivar) ? type : ObjectStates.settled(constr, type)
            [ivar, value] if ObjectStates.state_in(value)
          end.to_h
        end

        def rewritable?(constr, name, ivar)
          return false if memo_ivars(constr, name).include?(ivar)

          postconditions = constr.postconditions
          return true if postconditions.empty?

          constr.checker.factory.definition_builder.build_singleton(name).ancestors.ancestors.any? do |ancestor|
            postconditions.may_write?(ancestor.name.to_s, ivar)
          end
        rescue RBS::BaseError
          true
        end

        def memo_ivars(constr, name)
          ObjectStates.class_side_bodies(constr, AST::Types::Name::Singleton.new(name: name)).filter_map { |_, _, body| body&.memo&.first }.to_set
        end

        def named_classes(constr, call)
          names = Set[] #: Set[String]
          return names unless call.is_a?(TypeInference::MethodCall::Typed) && call.method_decls.size == 1

          method_name = call.method_decls.first.method_name
          singleton = method_name.is_a?(SingletonMethodName)
          visit_named(constr.constructor_bindings, method_name.type_name.to_s.delete_prefix("::"), method_name.method_name, singleton, names, Set[])
          names
        end

        def visit_named(registry, owner, method_name, singleton, names, seen)
          return unless seen.add?(method_name)

          body = singleton ? registry.singleton_body_of(owner, method_name) : registry.body_of(owner, method_name)
          return unless body

          names.merge(body.consts)
          body.self_sends.each { |sent| visit_named(registry, owner, sent, singleton, names, seen) }
        end
      end
    end
  end
end
