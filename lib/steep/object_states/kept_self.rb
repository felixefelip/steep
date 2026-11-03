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
        return if exposures(constr, body).any? { |node| !flow.dead?(node) }

        narrowed = !TypeInference::ConstructorBindingAnalyzer.self_exposures(body).empty?
        LocalReach.each_node(body) do |node|
          next unless self_call?(node)
          next narrowed ||= exposed?(constr, node) if flow.dead?(node) || typings_reaching(constr.typing, node).empty?
          next narrowed = true if kept_where_run?(constr, node)
          return if exposed?(constr, node)
        end
        narrowed || nil
      end

      # The nodes through which `self` may reach anything but a call on it
      # (`ConstructorBindingAnalyzer.self_exposures`), past a block the check
      # resolved to a core iteration: that runs before its call returns and
      # keeps nothing, so only what its own body hands on counts.
      def exposures(constr, node)
        TypeInference::ConstructorBindingAnalyzer.self_exposures(node).flat_map do |exposure|
          in_place?(constr, exposure) ? exposures(constr, exposure.children[2]) : [exposure]
        end
      end

      def in_place?(constr, node)
        return false unless %i[block numblock].include?(node.type)

        typings_reaching(constr.typing, node).all? do |typing|
          call = typing.call_of(node: node)
          call.is_a?(TypeInference::MethodCall::Typed) && call.method_decls.all? do |decl|
            IterationIntrinsics.entry(MethodIdentity.normalize(decl.method_name.to_s), override_registry: constr.literal_method_registry)
          end
        end
      rescue Typing::UnknownNodeError
        false
      end

      # The typings `node` was checked under: one per pass of every loop around
      # it that `record_iterations` expanded, or `typing` where none did. A
      # local the loop body assigns again has, in the method's own typing, the
      # type it had outside the loop.
      def typings_reaching(typing, node)
        around = typing.pass_typings.select { |loop, _| !loop.equal?(node) && inside?(loop.children[2], node) }
        loop, passes = around.max_by { |outer, _| outer.loc.expression.size }
        return [typing] unless loop

        passes.flat_map { |pass| typings_reaching(pass, node) }
      end

      def kept_where_run?(constr, node)
        typings_reaching(constr.typing, node).all? do |typing|
          ObjectStates.exit_of(typing.equal?(constr.typing) ? constr : constr.with_new_typing(typing), node, under: :stateful?)&.keeps_self
        end
      end

      def inside?(body, node)
        LocalReach.each_node(body) { |child| return true if child.equal?(node) }
        false
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
        callee ? ObjectStates.exposes_self?(constr, instance, callee, [method_name]) : !LiteralIntrinsics.answers_from_arguments?(constr, owner, method_name)
      end
    end
  end
end
