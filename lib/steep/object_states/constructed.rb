module Steep
  module ObjectStates
    # What an object holds once `Klass.new` has run its `initialize`, read off
    # that body checked under the call's arguments (felixefelip/steep#301):
    #
    #   def initialize(options)
    #     @options = normalized(options)   # { through: :taggings }
    #   end
    #
    # Each ivar the body assigns once, as a statement of its own after any
    # `super`, and mentions nowhere else, as the value assigned; kept where
    # `ObjectStates.settled` would keep it on any object. What the chain binds
    # from its arguments is `ObjectStates.built`'s, and the two are merged.
    module Constructed
      def self.record(constr, def_node, _pair)
        instance = constr.self_type
        return unless def_node.children[0] == :initialize && instance.is_a?(AST::Types::Name::Instance)

        assigned = assigned_values(constr.typing, def_node.children[2])
        state = ObjectStates.settled(constr, AST::Types::ObjectState.new(back_type: instance, ivars: assigned))
        root = constr.typing
        root = root.parent while root.parent
        root.add_exit_ivars(def_node, Exit.new(ivars: ObjectStates.state_in(state)&.ivars || {}, classes: {}))
      end

      # The state a `Klass.new` key was recorded under, as the object it
      # answers, or nil where its body left nothing known.
      def self.state(typing, def_node, key)
        ivars = typing&.exit_ivars_of(node: def_node)&.ivars
        return if ivars.nil? || ivars.empty?

        back_type = AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::#{key.delete_suffix(".new")}"), args: [])
        AST::Types::ObjectState.new(back_type: back_type, ivars: ivars)
      end

      def self.calls_super?(node)
        LocalReach.each_node(node) { |child| return true if %i[super zsuper].include?(child.type) }
        false
      end

      def self.assigned_values(typing, body)
        return {} unless body

        statements = body.type == :begin ? body.children : [body]
        last_super = statements.rindex { |statement| calls_super?(statement) }
        statements = statements.drop(last_super + 1) if last_super
        mentions = Hash.new(0) #: Hash[Symbol, Integer]
        LocalReach.each_node(body) { |node| mentions[node.children[0]] += 1 if %i[ivasgn ivar].include?(node.type) }
        statements.each_with_object({}) do |statement, values|
          ivar, value = statement.children
          next unless statement.type == :ivasgn && value && mentions[ivar] == 1 && typing.has_type?(value)

          values[ivar] = typing.type_of(node: value)
        end
      end
    end
  end
end
