module Steep
  module ObjectStates
    # Whether each value a memo's body reads ahead of the memo (`a` in
    # `a || @@x`, `HandedBack.fallbacks`) is `nil` or `false`, so the body hands
    # back the memo. Each reads nothing of that body, so it is typed where the
    # memo's call is, on a typing of its own.
    module MemoFallbacks
      FALSY = [AST::Types::Nil, AST::Types::Bot].freeze

      class << self
        def falsy?(constr, fallbacks)
          fallbacks.all? do |node|
            next false if typing.include?(node)

            typing << node
            begin
              falsy_type?(constr.with_new_typing(constr.typing.new_child).synthesize(node).type)
            ensure
              typing.delete(node)
            end
          end
        end

        private

        def typing = Thread.current[:steep_memo_fallbacks] ||= Set[].compare_by_identity

        def falsy_type?(type)
          case type
          when AST::Types::Union then type.types.all? { |member| falsy_type?(member) }
          when AST::Types::Literal then type.value == false
          else FALSY.any? { |klass| type.is_a?(klass) }
          end
        end
      end
    end
  end
end
