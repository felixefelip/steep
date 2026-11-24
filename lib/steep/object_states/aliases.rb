module Steep
  module ObjectStates
    # One object under several names in a body (felixefelip/rbs_infer#660):
    #
    #   catalog = Catalog.new          # Catalog{@lookups: {}}, built here
    #   Admin.new(catalog).clear       # Admin's @catalog is that object
    #   Reader.new(catalog).label      # so `catalog` holds what `clear` left
    #
    # Each object carries an `Id` (`ObjectState#origin`), as an object at run
    # time carries its `object_id`: the call of this body that answered it,
    # and where in that answer it sat. The ivar an `initialize` binds from an
    # argument keeps the argument's. A call that changes the object under one
    # name changes it under every name carrying the same `Id`.
    module Aliases
      # A node compared by identity: two calls written alike are two calls.
      class Id
        attr_reader :node, :path

        def initialize(node, path = [])
          @node = node
          @path = path
        end

        def ==(other) = other.is_a?(Id) && other.node.equal?(node) && other.path == path

        alias eql? ==

        def hash = node.object_id.hash ^ path.hash
      end

      class << self
        def labeled(constr, node, type)
          return type unless type.is_a?(AST::Types::ObjectState) && ObjectStates.held_value?(constr, node)

          type.with_origin(Id.new(node))
        end

        # `answer`, what the call `node` answered, with each object it holds
        # that was not handed to it (`known`) carrying an `Id` of this call:
        # the `Id`s the callee's own body gave them name objects of each of
        # its runs. None where `node` may run more than once.
        def reminted(constr, node, answer, known)
          return answer unless labeled?(answer)

          repeated = constr.method_context&.value_uses&.repeated?(node) != false
          minted(answer, []) { |origin, path| known.include?(origin) ? origin : (Id.new(node, path) unless repeated) }
        end

        def reminted_call(constr, call, node, receiver_type, arguments)
          reminted = reminted(constr, node, call.return_type, handed_origins(constr, arguments).merge(each_origin(receiver_type)))
          reminted.equal?(call.return_type) ? call : call.with_return_type(reminted)
        end

        # What `call` answered, where this body follows where it goes.
        def followed(constr, node, call)
          call.return_type if call && followed?(constr, node)
        end

        # `constr` with each of `locals` handed to a call settled to what holds
        # under any name, but one whose object `answer` carries, which is
        # followed under both names; and with every other local holding an
        # object an argument handed on settled too.
        def handed_on(constr, locals, arguments, answer)
          kept = each_origin(answer)
          constr = locals.reduce(constr) do |current, name|
            type = current.context.type_env[name] or next current
            next current if kept.include?(origin_of(type))

            ObjectStates.refine_local(current, name, ObjectStates.settled(current, type))
          end
          settled_elsewhere(constr, handed_origins(constr, arguments) - kept)
        end

        # The ivars `bindings` binds from an argument holding an object of
        # this body, carrying that object's origin.
        def bound(constr, type, bindings, arguments)
          return type unless type.is_a?(AST::Types::ObjectState)

          ivars = type.ivars.to_h do |ivar, value|
            index = bindings[ivar]
            argument = index && arguments[index]
            origin = argument && constr.typing.has_type?(argument) && origin_of(constr.typing.type_of(node: argument))
            [ivar, origin && value.is_a?(AST::Types::ObjectState) ? value.with_origin(origin) : value]
          end
          ivars == type.ivars && ivars.each_value.zip(type.ivars.each_value).all? { |left, right| left.equal?(right) } ? type : type.with_ivars(ivars)
        end

        def origin_of(type)
          ObjectStates.state_in(type)&.origin
        end

        # Whether `type` holds, at any depth, an object of this body.
        def labeled?(type)
          !each_labeled(type).first.nil?
        end

        def each_origin(type)
          each_labeled(type).to_set(&:origin)
        end

        # Whether the value of `node` goes where this body follows what it
        # holds: into a held local, as the receiver or an argument of another
        # call, or nowhere.
        def followed?(constr, node)
          uses = constr.method_context&.value_uses or return false
          ObjectStates.held_value?(constr, node) || uses.receiver?(node) || uses.argument?(node) || uses.left?(node)
        end

        # The objects of this body the values of `arguments` hold.
        def handed_origins(constr, arguments)
          LocalReach.argument_values(arguments).each_with_object(Set[]) do |argument, origins|
            origins.merge(each_origin(constr.typing.type_of(node: argument))) if constr.typing.has_type?(argument)
          end
        end

        # `constr` with each local holding one of `origins` settled: the
        # object went where no name here follows it.
        def settled_elsewhere(constr, origins)
          return constr if origins.empty?

          constr.context.type_env.local_variable_types.reduce(constr) do |current, (name, (type, _))|
            origins.include?(origin_of(type)) ? ObjectStates.refine_local(current, name, ObjectStates.settled(current, type)) : current
          end
        end

        # `after`, what a call left an object `before` stood for, with the
        # origin of each object `before` held at the same place.
        def relabeled(before, after)
          return after unless labeled?(before)

          case after
          when AST::Types::ObjectState
            return after unless before.is_a?(AST::Types::ObjectState) && before.back_type == after.back_type

            ivars = after.ivars.to_h { |ivar, value| [ivar, (held = before.ivars[ivar]) ? relabeled(held, value) : value] }
            after.with_ivars(ivars).with_origin(before.origin || after.origin)
          when AST::Types::Intersection
            state = ObjectStates.state_in(before)
            state ? after.map_type { |member| member.is_a?(AST::Types::ObjectState) ? relabeled(state, member) : member } : after
          else
            after
          end
        end

        # `constr` with every name holding an object `type` holds, at any
        # depth, holding it as `type` does.
        def spread(constr, type)
          table = each_labeled(type).to_h { |state| [state.origin, state] }
          return constr if table.empty?

          env = constr.context.type_env
          locals = env.local_variable_types.filter_map do |name, (local, _)|
            moved = replaced(local, table)
            [name, moved] unless moved.equal?(local)
          end.to_h
          ivars = env.instance_variable_types.filter_map do |name, held|
            moved = replaced(held, table)
            [name, moved] unless moved.equal?(held)
          end.to_h
          return constr if locals.empty? && ivars.empty?

          constr = locals.reduce(constr) { |current, (name, moved)| ObjectStates.refine_local(current, name, moved) }
          ivars.reduce(constr) { |current, (name, moved)| HeldIvar.refine(current, name, moved) }
        end

        private

        def minted(type, path, &block)
          case type
          when AST::Types::ObjectState
            ivars = type.ivars.to_h { |ivar, value| [ivar, minted(value, [*path, ivar], &block)] }
            origin = type.origin && yield(type.origin, path)
            type.with_ivars(ivars).with_origin(origin)
          when AST::Types::Union, AST::Types::Intersection
            type.map_type { |member| minted(member, path, &block) }
          when AST::Types::Tuple
            AST::Types::Tuple.new(types: type.types.each_with_index.map { |member, index| minted(member, [*path, index], &block) })
          else
            type
          end
        end

        def each_labeled(type, &block)
          return enum_for(__method__, type) unless block

          case type
          when AST::Types::ObjectState
            yield type if type.origin
            type.ivars.each_value { |value| each_labeled(value, &block) }
          when AST::Types::Union, AST::Types::Intersection, AST::Types::Tuple
            type.types.each { |member| each_labeled(member, &block) }
          end
        end

        def replaced(type, table)
          case type
          when AST::Types::ObjectState
            current = type.origin && table[type.origin]
            return current if current && !current.equal?(type)

            ivars = type.ivars.transform_values { |value| replaced(value, table) }
            ivars.each_value.zip(type.ivars.each_value).all? { |left, right| left.equal?(right) } ? type : type.with_ivars(ivars)
          when AST::Types::Union, AST::Types::Intersection, AST::Types::Tuple
            members = type.types.map { |member| replaced(member, table) }
            members.zip(type.types).all? { |left, right| left.equal?(right) } ? type : type.map_type { |member| replaced(member, table) }
          else
            type
          end
        end
      end
    end
  end
end
