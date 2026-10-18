module Steep
  module Specializations
    # The classes the receiver of each call naming a reader may be, as the
    # checker typed it, by the call's site (`ClassMemoAnalyzer.site`). A use of
    # a reader whose receiver can be no instance of a class says nothing of
    # the hash an instance of it keeps (felixefelip/steep#300).
    module Receivers
      SINGLETON = /\Asingleton\((.+)\)\z/

      class << self
        # Each call in `node` naming one of `names` on a receiver it can type.
        # A site whose receiver it cannot is nil: none of its classes is known.
        def collect(typing, node, names, found = {})
          return found unless node.is_a?(::Parser::AST::Node)

          receiver = node.children[0]
          if node.type == :send && names.include?(node.children[1]) && receiver.is_a?(::Parser::AST::Node) && receiver.type != :self
            site = TypeInference::ClassMemoAnalyzer.site(node)
            found[site] = typing.has_type?(receiver) ? classes(typing.type_of(node: receiver)) : nil if site
          end
          node.children.each { |child| collect(typing, child, names, found) }
          found
        end

        def classes(type)
          case type
          when AST::Types::Name::Instance then [type.name.to_s]
          when AST::Types::Name::Singleton then ["singleton(#{type.name})"]
          when AST::Types::ObjectState then classes(type.back_type)
          when AST::Types::Union then type.types.flat_map { |member| classes(member) or return nil }.uniq
          when AST::Types::Nil then ["::NilClass"]
          when AST::Types::Boolean then ["::TrueClass", "::FalseClass"]
          when AST::Types::Record then ["::Hash"]
          when AST::Types::Tuple then ["::Array"]
          when AST::Types::Literal then ["::#{type.value.class}"]
          end
        end

        # Whether a receiver of one of `classes` may be an instance of
        # `instance_name`: one of its ancestors, or of its descendants. A
        # module may be included anywhere.
        def may_be?(builder, classes, instance_name)
          classes.any? do |klass|
            if (singleton = klass[SINGLETON, 1])
              ancestor_names(builder.build_singleton(RBS::TypeName.parse(singleton))).include?(instance_name)
            else
              name = RBS::TypeName.parse(klass)
              name == instance_name || !builder.env.class_decl?(name) ||
                ancestor_names(builder.build_instance(name)).include?(instance_name) ||
                ancestor_names(builder.build_instance(instance_name)).include?(name)
            end
          end
        rescue RBS::BaseError
          true
        end

        private

        # A class object's ancestors name its own class, `Reflection` for
        # `singleton(Reflection)`, as singleton ancestors.
        def ancestor_names(definition)
          definition.ancestors.ancestors.filter_map { |ancestor| ancestor.name if ancestor.is_a?(RBS::Definition::Ancestor::Instance) }
        end
      end
    end
  end
end
