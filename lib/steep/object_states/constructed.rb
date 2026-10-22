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
    # `super`, and mentions nowhere else, as the value assigned, where a state
    # may hold it. Which of them hold for the object built is `kept`'s answer,
    # at the call; what the chain binds from its arguments is
    # `ObjectStates.built`'s, and the two are merged.
    module Constructed
      def self.constructor?(constr, def_node)
        def_node.children[0] == :initialize && constr.self_type.is_a?(AST::Types::Name::Instance)
      end

      def self.record(constr, def_node, _pair, params:)
        return unless constructor?(constr, def_node)

        chain = ObjectStates.initialize_chain(constr, constr.self_type)
        super_writes = chain.nil? || chain.drop(1).any? { |_, body| body }
        assigned = assigned_values(constr, def_node.children[2], super_writes: super_writes).filter_map do |ivar, value|
          value = HashMutation.storable(value) if value.is_a?(AST::Types::Record)
          [ivar, value] if value && ObjectStates.state_value?(value)
        end.to_h
        root = constr.typing
        root = root.parent while root.parent
        root.add_exit_ivars(def_node, Exit.new(ivars: assigned, classes: {}, params: params))
      end

      # The ivars of `state`, what a `Klass.new` recorded, that hold for the
      # object it answers: under any name, what `ObjectStates.settled` keeps;
      # held by a local nothing else names, any value nothing changes and an
      # array or a hash the checker follows, unless a method `initialize`
      # calls may assign it (`rewritten`).
      def self.kept(constr, state, held:, rewritten:)
        return {} unless state
        return ObjectStates.state_in(ObjectStates.settled(constr, state))&.ivars || {} unless held

        state.ivars.select do |ivar, value|
          !rewritten.include?(ivar) &&
            (ObjectStates.fixed?(value) || value.is_a?(AST::Types::Tuple) || HashMutation.held(constr, state.back_type, ivar, value, followed: true))
        end
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

      # `super_writes`: whether a `super` may reach an `initialize` that writes
      # ivars, which leaves only the assignments after the last one.
      def self.assigned_values(constr, body, super_writes:)
        return {} unless body

        statements = body.type == :begin ? body.children : [body]
        last_super = statements.rindex { |statement| calls_super?(statement) }
        statements = statements.drop(last_super + 1) if last_super && super_writes
        mentions = Hash.new(0) #: Hash[Symbol, Integer]
        LocalReach.each_node(body) { |node| mentions[node.children[0]] += 1 if %i[ivasgn ivar].include?(node.type) }
        statements.each_with_object({}) do |statement, values|
          ivar, value = statement.children
          next unless statement.type == :ivasgn && value && mentions[ivar] == 1 && constr.typing.has_type?(value)

          values[ivar] = constr.literal_operand_type(value, constr.typing.type_of(node: value))
        end
      end
    end
  end
end
