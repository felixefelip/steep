module Steep
  # A hash a local holds, kept in an ivar of `self` too, by a call that
  # answers it (felixefelip/steep#465):
  #
  #   def initialize(options)
  #     @options = normalize_options(options)
  #     @klass = options[:anonymous_class]
  #   end
  #
  # The local keeps following the record where every write any body may make
  # through the ivar, on an object of `self`'s class or of a class below it,
  # is a literal-key write: the record is widened by each.
  module HashMutation
    class << self
      def kept_in_ivar(constr, ivar, record)
        return unless record.is_a?(AST::Types::Record) && record.elements.each_value.all? { |value| record_value?(value) }

        instance = self_instance(constr) or return
        below = constr.checker.factory.descendant_index.descendants(instance.name, limit: ReflectionIntrinsics::MAX_DESCENDANTS) or return
        writes = [instance.name, *below].flat_map do |name|
          writes_to(constr, AST::Types::Name::Instance.new(name: name, args: []), ivar, kept: true) or return
        end
        value = declared_value(constr, instance, ivar)
        writes.reduce(record) { |held, use| widened_by(held, use, value) or return }
      end

      private

      def self_instance(constr)
        type = constr.self_type
        type = type.back_type if type.is_a?(AST::Types::ObjectState)
        type if type.is_a?(AST::Types::Name::Instance)
      end
    end
  end
end
