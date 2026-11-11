module Steep
  module ObjectStates
    # A block a method runs exactly once before it returns
    # (`Postconditions::RunsBlock`) leaves `self`'s ivars as it left them
    # (felixefelip/steep#370):
    #
    #   def []=(key, value)
    #     @write_lock.synchronize { super }   # what `super` stores holds after the call
    #   end
    #
    # One a method may run any other number of times leaves each ivar it
    # changes as it was before the call or as one pass left it, the rule a
    # `while` body follows. Only where the call is made on another object and
    # is not handed `self`: its body then has no way to change `self` around
    # the block.
    module BlockRun
      # Methods of the core's, written in C, that run the block they are
      # given while the call runs and keep nothing of it.
      RUNS_IN_PLACE = Set["::String#sub", "::String#sub!", "::String#gsub", "::String#gsub!"].freeze

      module_function

      def after(constr, node, receiver_type, method_name)
        return constr unless Accumulators::LAMBDA_BODIES.include?(node.type) && node.children[2]

        left = constr.typing.block_exit_of(node: node) or return constr
        entered = constr.context.type_env
        changed = left.instance_variable_types.keys.reject { |ivar| left[ivar] == entered[ivar] }
        return constr if changed.empty?

        once = !Tap.jumps?(node.children[2]) && runs_once?(constr, receiver_type, method_name)
        constr.update_type_env do |env|
          env.refine_types(instance_variable_types: changed.to_h { |ivar| [ivar, once ? left[ivar] : either(entered, left, ivar)] })
        end
      end

      def either(entered, left, ivar)
        AST::Types::Union.build(types: [entered[ivar] || entered.declared_instance_variable_type(ivar) || AST::Builtin.nil_type, left[ivar]])
      end

      # Whether each `[ivar, method]` is, on the type `instance` declares the
      # ivar with, a method that runs its block before it returns and keeps
      # nothing of it: an iteration of the core's, or one whose body runs it
      # once (`Postconditions::RunsBlock`).
      def in_place?(constr, instance, iterations)
        return false if iterations.nil? || iterations.empty? || !instance.is_a?(AST::Types::Name::Instance)

        variables = constr.checker.factory.definition_builder.build_instance(instance.name).instance_variables
        iterations.all? do |ivar, method_name|
          declared = variables[ivar] or next false
          in_place_on?(constr, constr.checker.factory.type(declared.type), method_name, private: false)
        end
      rescue RBS::BaseError
        false
      end

      # `in_place?` of the call at `site` (`ClassMemoAnalyzer.site`), by the
      # type its receiver has there (`Specializations::Receivers`).
      def runs_in_place?(constr, site, method_name)
        type = constr.specializations.receiver_type(site, factory: constr.checker.factory) or return false
        in_place_on?(constr, type, method_name, private: true)
      rescue RBS::BaseError
        false
      end

      def in_place_on?(constr, type, method_name, private:)
        keys = MethodIdentity.keys(constr, type, method_name, private: private)
        return true if !keys.empty? && keys.all? { |key| RUNS_IN_PLACE.include?(key) || IterationIntrinsics.entry(key, override_registry: constr.literal_method_registry) }

        runs_once?(constr, type, method_name)
      end

      def runs_once?(constr, receiver_type, method_name)
        receiver = ObjectStates.state_in(receiver_type)&.back_type || receiver_type
        return false unless receiver.is_a?(AST::Types::Name::Instance) || receiver.is_a?(AST::Types::Name::Singleton)

        owner, = ObjectStates.resolved_body(constr, receiver, method_name)
        owner && constr.postconditions.lookup_instance(owner, method_name)&.runs_block || false
      end
    end
  end
end
