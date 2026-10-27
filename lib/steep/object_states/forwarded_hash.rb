module Steep
  module ObjectStates
    # A hash an object keeps in an ivar of its own, reached only through
    # methods that forward to it (felixefelip/steep#369):
    #
    #   class Map
    #     def initialize = @backend = {}
    #     def [](key) = @backend[key]                     # `Body#hands_back_element`
    #     def []=(key, value) = (@backend[key] = value)   # `Body#stores_element`
    #   end
    #
    #   @instances = Map.new                # @instances: Map{@backend: {}}
    #
    # A class body's ivar holding such an object is a hash memo whose record
    # sits in the object's state.
    module ForwardedHash
      module_function

      # The ivar of `instance` whose hash `instance#[]` hands back an element
      # of.
      def nested(constr, instance)
        memo = ObjectStates.resolved_body(constr, instance, :[])&.last&.hands_back_element&.first
        memo if memo&.start_with?("@")
      end

      # The record the object `type` is a state of keeps in `nested`.
      def record(constr, type)
        state = ObjectStates.state_in(type) or return
        nested = nested(constr, state.back_type) or return
        record = state.ivars[nested]
        record if record.is_a?(AST::Types::Record)
      end

      # The object `type` with `record` as the hash it keeps.
      def with_record(constr, type, record)
        state = ObjectStates.state_in(type) or raise
        AST::Types::ObjectState.new(back_type: state.back_type, ivars: state.ivars.merge(nested(constr, state.back_type) => record))
      end

      # `[key index, value index]` where `method_name` stores into the hash
      # `instance` keeps in `nested`: itself, or by a `super` in a block
      # handed to a method that runs it once (`BlockRun`, felixefelip/steep#370).
      def store(constr, instance, nested, method_name)
        owner, body = ObjectStates.resolved_body(constr, instance, method_name)
        store_of(constr, instance, nested, method_name, owner, body)
      end

      def store_of(constr, instance, nested, method_name, owner, body)
        ivar, key_index, value_index = body&.stores_element
        return [key_index, value_index] if ivar == nested

        holder, runner = body&.block_super
        held = holder && constr.checker.factory.definition_builder.build_instance(instance.name).instance_variables[holder] or return
        return unless BlockRun.runs_once?(constr, constr.checker.factory.type(held.type), runner)

        reached = super_body(constr, instance, owner, method_name) or return
        store_of(constr, instance, nested, method_name, *reached)
      rescue RBS::BaseError
        nil
      end

      # The body a `super` in `owner`'s `method_name` reaches, on `instance`.
      def super_body(constr, instance, owner, method_name)
        registry = constr.constructor_bindings
        ancestors = constr.checker.factory.definition_builder.build_instance(instance.name).ancestors.ancestors
        index = ancestors.index { |ancestor| ancestor.name == owner } or return
        ancestor = ancestors.drop(index + 1).find { |candidate| ObjectStates.ancestor_defines?(registry, candidate, method_name) } or return
        bodies = ObjectStates.ancestor_bodies(registry, ancestor)[method_name]
        [ancestor.name, bodies.first] if bodies&.size == 1
      end

      # Every method of `instance` that stores into the hash it keeps in
      # `nested`.
      def store_names(constr, instance, nested)
        registry = constr.constructor_bindings
        constr.checker.factory.definition_builder.build_instance(instance.name).ancestors.ancestors.flat_map do |ancestor|
          registry.method_bodies(ancestor.name.to_s).keys.select { |name| store(constr, instance, nested, name) }
        end.to_set
      rescue RBS::BaseError
        Set[]
      end
    end
  end
end
