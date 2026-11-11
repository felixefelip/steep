module Steep
  module ObjectStates
    # What a body leaves holding, where it falls off its end and where it
    # returns.
    module Exits
      module_function

      # The env at each `return` the checker reached, or nil where one has
      # none.
      def returned(typing, body)
        flow = Specializations::Evals::Flow.new(typing)
        envs = [] #: Array[TypeInference::TypeEnv]
        Accumulators::ReturnedValues.each_return(body) do |node|
          next if flow.dead?(node)

          envs << (typing.jump_env_of(node: node) or return)
        end
        envs
      end

      # What `env` holds, of the ivars a body was entered with, that a state
      # may hold.
      def entered_values(env, arguments)
        arguments.self_ivars.keys.to_h { |ivar| [ivar, env[ivar]] }.select { |_, type| ObjectStates.state_value?(type) }
      end

      # What every one of `exits` holds alike.
      def common(exits)
        first, *rest = exits
        (first || {}).select { |name, type| rest.all? { |other| other[name] == type } }
      end
    end
  end
end
