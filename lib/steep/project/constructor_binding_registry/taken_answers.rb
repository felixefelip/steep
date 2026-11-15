module Steep
  class Project
    class ConstructorBindingRegistry
      # Which names the project's calls take the answer of, read off each
      # source as it is ingested: the registry drops its nodes once built.
      module TakenAnswers
        # Whether a call of `name` anywhere in the project may take what it
        # answers (`TypeInference::TakenAnswers`).
        def answer_taken?(name) = (@taken_answers ||= Set[]).include?(name.to_sym)

        private

        def keep_node(node)
          @nodes << node
          TypeInference::TakenAnswers.of(node, @taken_answers ||= Set[])
        end
      end

      include TakenAnswers
    end
  end
end
