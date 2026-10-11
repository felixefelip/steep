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
    # Only the memos `ClassMemos` follows keep their state past the body:
    # nothing but a statement of that body may change what they hold. A method
    # runs whenever it is called, so it is entered with the states its call
    # site knew (`of_call`), not the ones around its definition.
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

        private

        # `self`'s ivars a body leaves known: its memos' objects, the only ones
        # no class method may rewrite.
        def held(constr, singleton)
          memos = memo_ivars(constr, singleton.name)
          ObjectStates.self_ivars(constr).select { |ivar, _| memos.include?(ivar) }
        end

        def memo_ivars(constr, name)
          registry = constr.constructor_bindings
          ancestors = constr.checker.factory.definition_builder.build_singleton(name).ancestors.ancestors
          ancestors.flat_map { |ancestor| registry.singleton_method_bodies(ancestor.name.to_s).values.flatten.filter_map { |body| body&.memo&.first } }.to_set
        rescue RBS::BaseError
          Set[]
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
