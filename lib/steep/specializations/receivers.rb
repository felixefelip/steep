module Steep
  module Specializations
    # The type the checker gave the receiver of each call naming a reader, by
    # the call's site (`ClassMemoAnalyzer.site`). A use of a reader whose
    # receiver can be no value of a type says nothing of the object of that
    # type.
    module Receivers
      SENDS = %i[send csend].freeze

      class << self
        # Each call in `node` naming one of `names` on an explicit receiver,
        # with the receiver's type as RBS. A site whose receiver the checker
        # did not type, or typed relative to where it is, is nil.
        def collect(typing, node, names, found = {})
          return found unless node.is_a?(::Parser::AST::Node)

          receiver = node.children[0]
          if SENDS.include?(node.type) && names.include?(node.children[1]) && receiver.is_a?(::Parser::AST::Node) && receiver.type != :self
            site = TypeInference::ClassMemoAnalyzer.site(node)
            found[site] = typing.has_type?(receiver) ? written(typing.type_of(node: receiver)) : nil if site
          end
          node.children.each { |child| collect(typing, child, names, found) }
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
          constr.constructor_bindings.calls_of(name).reject { |call| elsewhere?(constr, call, target) }
        end

        # Whether `call` may run the method of the project's it names: its
        # receiver may be a value of a class that defines it. A receiver typed
        # `untyped` is taken as none of them.
        def reaches?(constr, call)
          owners = constr.constructor_bindings.owners_of(call.called)
          owners.empty? || owners.any? do |class_name, singleton|
            name = RBS::TypeName.parse("::#{class_name}")
            target = singleton ? AST::Types::Name::Singleton.new(name: name) : AST::Types::Name::Instance.new(name: name, args: [])
            !elsewhere?(constr, call, target)
          end
        end

        private

        def written(type)
          type = Specializations.rbs_writable(readable(type))
          type.to_s if type.free_variables.empty?
        end

        def readable(type)
          type.is_a?(AST::Types::Logic::Base) ? AST::Builtin.bool_type : type.map_type { |child| readable(child) }
        end

        def elsewhere?(constr, use, target)
          factory = constr.checker.factory
          type = use.at && constr.specializations.receiver_type(use.at, factory: factory) or return false
          return true if type.is_a?(AST::Types::Any)

          target = factory.instance_type(target.name) if target.is_a?(AST::Types::Name::Instance)
          interpreter = TypeInference::LogicTypeInterpreter.new(subtyping: constr.checker, typing: constr.typing, config: constr.builder_config)
          interpreter.type_case_select0(type, target)[0].empty?
        rescue RBS::BaseError
          false
        end
      end
    end
  end
end
