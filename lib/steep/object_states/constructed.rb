module Steep
  module ObjectStates
    # What an object holds once `Klass.new` has run its `initialize`, read off
    # that body checked under the call's arguments, entered with an object
    # that holds nothing yet (felixefelip/steep#301, #367):
    #
    #   def initialize(options = nil)
    #     super(options)                   # `@backend = {}` in the parent's
    #     @options = normalized(options)   # { through: :taggings }
    #   end
    #
    # Each ivar as the body left it, through a `super` and the methods it
    # calls on `self` as their own checks left it, where a state may hold it.
    # Which of them hold for the object built is `kept`'s answer, at the call;
    # what the chain binds from its arguments is `ObjectStates.built`'s, and
    # the two are merged.
    module Constructed
      def self.constructor?(constr, def_node)
        def_node.children[0] == :initialize && constr.self_type.is_a?(AST::Types::Name::Instance)
      end

      def self.record(constr, def_node, pair, params:)
        return unless constructor?(constr, def_node)

        arguments = constr.specialization_arguments(def_node) or return
        written = written_ivars(constr, constr.self_type)
        assigned = arguments.self_ivars.each_key.filter_map do |ivar|
          value = pair.context.type_env[ivar]
          value = HashMutation.storable(value) if value.is_a?(AST::Types::Record)
          [ivar, value] if value && ObjectStates.state_value?(value) && (written.include?(ivar) || !value.is_a?(AST::Types::Nil))
        end.to_h
        root = constr.typing
        root = root.parent while root.parent
        root.add_exit_ivars(def_node, Exit.new(ivars: assigned, classes: {}, params: params))
      end

      # What the `initialize` chain may assign, itself or through a method it
      # calls on `self`: an ivar it never does is `nil` only for not being set.
      def self.written_ivars(constr, instance)
        chain = ObjectStates.initialize_chain(constr, instance) || []
        chain.each_with_object(Set[]) do |(_, body), written|
          written.merge(body.writes).merge(ObjectStates.callee_writes(constr, instance, body, [:initialize])) if body
        end
      end

      # The ivars of `state`, what a `Klass.new` recorded, that hold for the
      # object it answers: under any name, what `ObjectStates.settled` keeps;
      # held by a local nothing else names, any value nothing changes and an
      # array or a hash the checker follows.
      def self.kept(constr, state, held:)
        return {} unless state
        return ObjectStates.state_in(ObjectStates.settled(constr, state))&.ivars || {} unless held

        state.ivars.select do |ivar, value|
          ObjectStates.fixed?(value) || value.is_a?(AST::Types::Tuple) || HashMutation.held(constr, state.back_type, ivar, value, followed: true)
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
    end
  end
end
