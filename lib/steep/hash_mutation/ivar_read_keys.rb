module Steep
  module HashMutation
    # The keys a `Hash.new` block an ivar holds may receive: every read of the
    # ivar's hash, by any method an object holding it may run, where each one
    # mentions the hash only to read, store or query it by key and none lets it
    # out. A read's key is a literal or a parameter, as declared.
    #
    #   def set_backend = @backend = Hash.new { |_hash, key| key.to_s }
    #   def [](key) = @backend[key]     # key: what `[]` declares
    module IvarReadKeys
      DESCENDANT_LIMIT = 50

      class << self
        def of(constr, node)
          instance = constr.self_type
          return unless instance.is_a?(AST::Types::Name::Instance)

          ivar = ObjectStates::HeldIvar.held_ivars(constr)&.held_name(node) or return
          keys = [] #: Array[AST::Types::t]
          owners(constr, instance.name)&.each do |owner|
            constr.constructor_bindings.possible_bodies(owner.to_s).each do |method_name, bodies|
              bodies.each { |body| keys.concat(body_keys(constr, owner, method_name, body, ivar) || (return)) }
            end
          end
          keys unless keys.empty?
        rescue RBS::BaseError
          nil
        end

        # Every module whose methods an object of `name`, or of a class below
        # it, may run.
        def owners(constr, name)
          builder = constr.checker.factory.definition_builder
          below = constr.checker.factory.descendant_index.descendants(name, limit: DESCENDANT_LIMIT) or return
          [name, *below].flat_map { |klass| builder.build_instance(klass).ancestors.ancestors.map(&:name) }.uniq
        end

        def body_keys(constr, owner, method_name, body, ivar)
          return if body.nil? || body.returns == ivar || body.handed.include?(ivar)

          body.ivar_uses.fetch(ivar, []).filter_map do |use|
            return unless keyed?(use)
            next unless use.called == :[]

            key_type(constr, owner, method_name, use) || (return)
          end
        end

        def keyed?(use)
          !%i[escape yielded].include?(use.kind) && use.element_calls.empty? && !use.forwarded_by && !use.handed && KEYED_MENTIONS.include?(use.called)
        end

        def key_type(constr, owner, method_name, use)
          return AST::Types::Literal.new(value: use.key) if use.key

          index = use.key_param or return
          method = constr.checker.factory.definition_builder.build_instance(owner).methods[method_name] or return
          types = method.method_types.map do |method_type|
            params = constr.checker.factory.method_type(method_type).type.params or return
            [*params.required, *params.optional][index] or return
          end
          AST::Types::Union.build(types: types)
        end
      end
    end
  end
end
