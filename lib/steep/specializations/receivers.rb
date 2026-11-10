module Steep
  module Specializations
    # The type the checker gave the receiver of each call naming a reader, by
    # the call's site (`ClassMemoAnalyzer.site`). A use of a reader whose
    # receiver can be no value of a type says nothing of the object of that
    # type.
    module Receivers
      SENDS = %i[send csend].freeze

      class << self
        # Each call in `node` naming one of `names`, with the receiver's type
        # as RBS: on `self`, the type `self` has where the call is made
        # (`call`, which a call with a block is recorded on). A site whose
        # receiver the checker did not type, or typed relative to where it
        # is, is nil.
        def collect(typing, node, names, found = {}, call: node)
          return found unless node.is_a?(::Parser::AST::Node)

          if SENDS.include?(node.type) && names.include?(node.children[1]) && (site = TypeInference::ClassMemoAnalyzer.site(node))
            found[site] = receiver_written(typing, node.children[0], call)
          end
          node.children.each_with_index do |child, index|
            collect(typing, child, names, found, call: Accumulators::LAMBDA_BODIES.include?(node.type) && index.zero? ? node : child)
          end
          found
        end

        # Adds what `collect` found to `receivers`: a site read by two targets
        # keeps what both typed it as, and one a target could not type is
        # dropped for good (`unknown`).
        def record(receivers, unknown, found)
          found.each do |site, type|
            if type.nil? || unknown.include?(site)
              unknown << site
              receivers.delete(site)
            else
              receivers[site] = receivers.fetch(site, []) | [type]
            end
          end
        end

        # The uses of `name` whose receiver may be a value of `target`.
        def uses_on(constr, name, target, every: false)
          registry = constr.constructor_bindings
          (every ? registry.every_use_of(name) : registry.uses_of(name)).reject { |use| elsewhere?(constr, use, target) }
        end

        # The calls of `name` whose receiver may be a value of `target`
        # (`ConstructorBindingRegistry#calls_of`).
        def calls_on(constr, name, target)
          registry = constr.constructor_bindings
          constr.specializations.keep([:calls_on, constr.checker, registry, name, target]) do
            registry.calls_of(name).reject { |call| elsewhere?(constr, call, target) }.freeze
          end
        end

        # Whether `call` may run one of the methods of the project's it names
        # that `owners` define (`ConstructorBindingRegistry#owners_of`): its
        # receiver may be a value of one of them. A receiver typed `untyped`
        # is taken as none of them.
        def reaches?(constr, call, owners)
          owners.empty? || owners.any? do |class_name, singleton|
            name = RBS::TypeName.parse("::#{class_name}")
            target = singleton ? AST::Types::Name::Singleton.new(name: name) : AST::Types::Name::Instance.new(name: name, args: [])
            !elsewhere?(constr, call, target)
          end
        end

        private

        def receiver_written(typing, receiver, call)
          if receiver.nil? || receiver.type == :self
            type = typing.self_type_of_call(node: call)
            type && written(type)
          elsif typing.has_type?(receiver)
            written(typing.type_of(node: receiver))
          end
        end

        def written(type)
          type = erase_parameters(Specializations.rbs_writable(readable(type)))
          type.to_s if type.free_variables.empty?
        end

        # What a value of a class may be does not depend on its parameters.
        def erase_parameters(type)
          return type unless type.is_a?(AST::Types::Name::Instance)

          variables = type.free_variables.grep(Symbol)
          type.subst(Interface::Substitution.build(variables, variables.map { AST::Builtin.any_type }))
        end

        def readable(type)
          type.is_a?(AST::Types::Logic::Base) ? AST::Builtin.bool_type : type.map_type { |child| readable(child) }
        end

        def elsewhere?(constr, use, target)
          factory = constr.checker.factory
          type = receiver_of(constr, use) or return false
          return true if type.is_a?(AST::Types::Any)

          target = factory.instance_type(target.name) if target.is_a?(AST::Types::Name::Instance)
          interpreter = TypeInference::LogicTypeInterpreter.new(subtyping: constr.checker, typing: constr.typing, config: constr.builder_config)
          interpreter.type_case_select0(type, target)[0].empty?
        rescue RBS::BaseError
          false
        end

        def receiver_of(constr, use)
          factory = constr.checker.factory
          site = use.at || use.self_at
          return constr.specializations.receiver_type(site, factory: factory) if site
          return if use.kind != :escape || use.owner.to_s.empty?

          name = RBS::TypeName.parse("::#{use.owner}")
          factory.instance_type(name) if factory.definition_builder.env.module_class_entry(name)
        end
      end
    end
  end
end
