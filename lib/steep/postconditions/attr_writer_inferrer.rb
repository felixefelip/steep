module Steep
  module Postconditions
    # felixefelip/steep#219. An `attr_writer :name` / `attr_accessor :name`
    # writes `@name` with no `def name=` for `Inferrer#walk_classes` to find, so
    # its effect is read from the RBS instead — the same `AttrWriter` /
    # `AttrAccessor` member and `ivar_name` `attr_method_backing_ivar` reads.
    # The RBS covers the attrs rbs_infer generates as well as hand-written ones.
    #
    # One entry per writer the class or module declares itself (an inherited
    # one is recorded where it is declared, which is what `ObjectStates` walks
    # the ancestors for), for every class or module the source opens.
    class AttrWriterInferrer
      def initialize(definition_builder)
        @definition_builder = definition_builder
      end

      # Returns `Array[InferredEntry]`, each with only `may_write_ivars` set.
      def entries(node)
        class_names = Set.new #: Set[String]
        each_opened_class(node, nesting: []) { |class_name| class_names << class_name }

        class_names.flat_map do |class_name|
          [false, true].flat_map do |singleton|
            writer_ivars(class_name, singleton: singleton).map do |method_name, ivar|
              InferredEntry.new(
                class_name: class_name,
                method_name: method_name,
                singleton: singleton,
                may_write_ivars: Set[ivar]
              )
            end
          end
        end
      end

      private

      # `Hash[Symbol, Symbol]`: each `name=` the class declares through an attr,
      # to the ivar it writes. An attr declared `ivar_name: false` has none. (An
      # attr declares its ivar itself, so unlike `Inferrer#collect_ivar_writes`
      # there is no undeclared one to leave out.)
      def writer_ivars(class_name, singleton:)
        type_name = RBS::TypeName.parse("::#{class_name}").absolute!
        definition =
          if singleton
            @definition_builder.build_singleton(type_name) rescue nil
          else
            @definition_builder.build_instance(type_name) rescue nil
          end
        return {} unless definition

        definition.methods.each_with_object({}) do |(method_name, method), writers| #$ Hash[Symbol, Symbol]
          next unless method_name.end_with?("=")

          method.defs.each do |type_def|
            next unless type_def.implemented_in == type_name

            member = type_def.member
            next unless member.is_a?(RBS::AST::Members::AttrWriter) || member.is_a?(RBS::AST::Members::AttrAccessor)
            next if member.ivar_name == false

            writers[method_name] = member.ivar_name || :"@#{member.name}"
          end
        end
      end

      # Yields the name of every class and module the source opens, under the
      # nesting-text naming `Inferrer#walk_classes` gives their methods.
      def each_opened_class(node, nesting:, &block)
        return unless node.is_a?(Parser::AST::Node)

        case node.type
        when :class, :module
          const_node, *, body = node.children
          name = const_name(const_node)
          if name
            nesting += [name]
            yield nesting.join("::")
          end
          each_opened_class(body, nesting: nesting, &block) if body
        else
          node.children.each { |child| each_opened_class(child, nesting: nesting, &block) }
        end
      end

      # Same as `Inferrer#extract_const_name`, so both key a class alike.
      def const_name(node)
        return nil unless node.is_a?(Parser::AST::Node) && node.type == :const

        parent, name = node.children
        parent_name = const_name(parent)
        parent_name ? "#{parent_name}::#{name}" : name.to_s
      end
    end
  end
end
