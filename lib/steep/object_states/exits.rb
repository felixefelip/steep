module Steep
  module ObjectStates
    # The ways a body leaves besides falling off its end.
    module Exits
      module_function

      # The env at each `return` the checker reached, or nil where one has
      # none.
      def returned(typing, body)
        flow = Specializations::Evals::Flow.new(typing)
        envs = [] #: Array[TypeInference::TypeEnv]
        ReturnedValues.each_return(body) do |node|
          next if flow.dead?(node)

          envs << (typing.jump_env_of(node: node) or return)
        end
        envs
      end

      # What every one of `exits` holds alike.
      def common(exits)
        first, *rest = exits
        (first || {}).select { |name, type| rest.all? { |other| other[name] == type } }
      end
    end
  end
end
