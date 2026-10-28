module Steep
  module ObjectStates
    # Whether a body checked under its arguments keeps `self` where its text
    # may hand it on (felixefelip/steep#371):
    #
    #   def set_backend(default_proc)
    #     if default_proc
    #       @backend = Hash.new { |_h, key| default_proc.call(self, key) }
    #     else
    #       @backend = {}                  # all `nil` runs
    #     end
    #   end
    #
    # `true` where no node the check reached hands `self` on, nor any body it
    # reached by a call on `self` or a `super`, while the text alone says one
    # may: a node that does sits where the check never went, or a body reached
    # was kept by its own check. nil where the text's answer
    # (`ObjectStates.exposes_self?`) stands.
    module KeptSelf
      module_function

      def kept?(constr, def_node)
        body = ObjectStates.pair_body(def_node) or return
        flow = Specializations::Evals::Flow.new(constr.typing)
        exposures = TypeInference::ConstructorBindingAnalyzer.self_exposures(body)
        return if exposures.any? { |node| !flow.dead?(node) }

        narrowed = !exposures.empty?
        LocalReach.each_node(body) do |node|
          next unless self_call?(node)
          next narrowed ||= exposed?(constr, node) if flow.dead?(node)
          next narrowed = true if ObjectStates.exit_of(constr, node, under: :stateful?)&.keeps_self
          return if exposed?(constr, node)
        end
        narrowed || nil
      end

      # Whether nothing but its holder has the object `Klass.new` called as
      # `arguments_key` builds: its check kept `self`, or no body
      # of its `initialize` chain hands `self` on.
      def fresh_chain?(constr, instance, chain, arguments_key)
        return true if arguments_key && constr.specializations.keeps_self?(ObjectStates.constructor_key(chain), arguments_key)

        chain.none? { |_, body| body && ObjectStates.exposes_self?(constr, instance, body, [:initialize]) }
      end

      # Whether the store keeps what a body checked under `arguments` left:
      # what its receiver or the records it was handed hold, or that it kept
      # `self`.
      def exit_kept?(arguments, exit)
        arguments.stateful? || arguments.hands_records? || exit&.keeps_self == true
      end

      def self_call?(node)
        %i[super zsuper].include?(node.type) || (%i[send csend].include?(node.type) && (node.children[0].nil? || node.children[0].type == :self))
      end

      # The text's answer for the body a call on `self` or a `super` reaches.
      def exposed?(constr, node)
        instance = constr.self_type
        return true unless instance.is_a?(AST::Types::Name::Instance) || instance.is_a?(AST::Types::Name::Singleton)
        return reached_exposes?(constr, instance, instance, node.children[1]) unless %i[super zsuper].include?(node.type)

        call = ObjectStates.recorded_call(constr, node)
        return false if Supers.core_initializer?(call, node)
        return true unless call.is_a?(TypeInference::MethodCall::Typed) && instance.is_a?(AST::Types::Name::Instance)

        call.method_decls.any? do |decl|
          owner = AST::Types::Name::Instance.new(name: decl.method_name.type_name, args: [])
          reached_exposes?(constr, instance, owner, decl.method_name.method_name)
        end
      end

      def reached_exposes?(constr, instance, owner, method_name)
        _, callee = ObjectStates.resolved_body(constr, owner, method_name)
        callee.nil? || ObjectStates.exposes_self?(constr, instance, callee, [method_name])
      end
    end
  end
end
