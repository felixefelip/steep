module Steep
  module ObjectStates
    # What `Klass.allocate` holds: no `initialize` ran on it, so every ivar
    # the class declares is unset.
    module Allocated
      def self.state(constr, instance)
        ivars = constr.checker.factory.definition_builder.build_instance(instance.name).instance_variables
        AST::Types::ObjectState.new(back_type: instance, ivars: ivars.keys.to_h { |ivar| [ivar, AST::Builtin.nil_type] })
      rescue RBS::BaseError
        nil
      end

      # Whether a call leaves `singleton`'s `ivar` as it was while unset: the
      # memo `@ivar ||= allocate` is all that writes or reads it, set or
      # unset, `ClassMemos.settled_memo` answers the same object, and no
      # class state follows that object (`ClassMemos.tracked`).
      def self.kept_unset?(constr, singleton, ivar)
        bodies = ObjectStates.class_side_bodies(constr, singleton)
        memos = bodies.select { |_, _, body| body&.memoizes == ivar }
        return false unless memos.size == 1

        owner, method_name, body = memos.first
        _, _, wrappers, _, allocated, fallbacks = body.memo
        return false unless allocated && wrappers&.empty? && MemoFallbacks.falsy?(constr, fallbacks)

        MemoSlots.written_only_by?(constr, singleton, ivar, owner, method_name) &&
          bodies.all? { |name, other, read| (name == owner && other == method_name) || (read && !read.ivars.include?(ivar)) }
      end
    end
  end
end
