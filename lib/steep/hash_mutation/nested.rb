module Steep
  # A record a held record keeps under a key, one level down
  # (felixefelip/steep#314):
  #
  #   foo.my_hash[:bar] = { num1: 5, num2: 10 }   # @my_hash: { bar: { num1: 5, num2: 10 } }
  #   foo.my_hash[:bar][:num2] = 30               # @my_hash: { bar: { num1: 5, num2: 30 } }
  #
  # It is born of a literal stored through a followed path where nothing in
  # the body takes the store's value (`TypeInference::ValueUses`), and stays a
  # record while every call made on it, or on the record that keeps it, is a
  # step of such a path: a key read by literal, a key store or `delete`, or a
  # read that hands nothing out. Anywhere else it may get a second name, so
  # from there on it is held as its class.
  #
  # Only what is followed is touched: an object's state, or an ivar of `self`
  # a body was entered with. A record a signature declares is the type it
  # declares.
  module HashMutation
    QUIET_READS = %w[key? has_key? include? member? size length empty? keys].map { |name| "::Hash##{name}" }.freeze

    STEPS = (KEY_READ | WRITES | QUIET_READS).freeze

    class << self
      # A value a followed record may hold under a key.
      def held_value?(type)
        record_value?(type) || (type.is_a?(AST::Types::Record) && type.elements.each_value.all? { |value| record_value?(value) })
      end

      # `type`, a followed value, with every record a record holds held as its
      # class.
      def flatten(type)
        return type unless nested_in?(type)

        case type
        when AST::Types::Record
          elements = type.elements.transform_values { |value| value.is_a?(AST::Types::Record) ? storable_value(value) || value : value }
          AST::Types::Record.new(elements: elements, required_keys: type.required_keys)
        when AST::Types::ObjectState
          AST::Types::ObjectState.new(back_type: type.back_type, ivars: type.ivars.transform_values { |value| flatten(value) })
        else
          type.class.build(types: type.types.map { |member| flatten(member) })
        end
      end

      # A call on a record a followed holder keeps, or on one it keeps under
      # a key, that is no step: the holder keeps its records' records as
      # their class from here, and the call runs on what it then holds.
      def consumed(constr, receiver, receiver_type, keys, block:)
        return unless receiver && (holder = holder_of(constr, receiver) || path(constr, receiver)&.first)
        return unless nested_in?(holder_record(constr, holder)) && (block || !CollectionMutation.only?(constr, keys, STEPS))

        flat = holder_of(constr, receiver) ? flatten(receiver_type) : storable_value(receiver_type) || receiver_type
        [flat, flattened(constr, holder)]
      end

      # `consumed` for a key read by no literal, which may answer any record
      # the holder keeps.
      def read_by_key(constr, receiver, arguments, type)
        key, = CollectionMutation.operand_types(constr, arguments)
        return [type, constr] if key.is_a?(AST::Types::Literal) || !(holder = holder_of(constr, receiver))
        return [type, constr] unless nested_in?(holder_record(constr, holder))

        [as_class(type), flattened(constr, holder)]
      end

      # A hash whose record keeps one, read off a followed holder and taken
      # or returned, comes out with it held as its class: `answer_taken`
      # makes every holder forget it, and the name it gets has to agree.
      def handed_out(call, node, constr, receiver_type)
        type = call.return_type
        return call unless type.is_a?(AST::Types::Record) && nested_in?(type) && !receiver?(constr, node) && followed_read?(constr, call, node, receiver_type)

        call.with_return_type(flatten(type))
      end

      # Once a call is done, one whose answer holds a record something in the
      # body takes may have handed out one a state keeps, so every followed
      # variable here forgets them.
      def answer_taken(constr, node)
        return constr unless taken?(constr, node)

        call = ObjectStates.recorded_call(constr, node)
        call && record_in?(call.return_type) ? forgotten(constr) : constr
      end

      # `@ivar`, one the body was entered with, read anywhere but as a
      # receiver.
      def read_ivar(constr, node, type)
        name = node.children[0]
        return constr.add_typing(node, type: type) unless nested_in?(type) && entered_ivar?(constr, name) && !receiver?(constr, node)

        ObjectStates::HeldIvar.refine(constr, name, flatten(type)).add_typing(node, type: flatten(type))
      end

      private

      def nested_in?(type)
        case type
        when AST::Types::Record then type.elements.each_value.any?(AST::Types::Record)
        when AST::Types::ObjectState then type.ivars.each_value.any? { |value| nested_in?(value) }
        when AST::Types::Union, AST::Types::Intersection then type.types.any? { |member| nested_in?(member) }
        else false
        end
      end

      def record_in?(type)
        case type
        when AST::Types::Record then true
        when AST::Types::Union, AST::Types::Intersection, AST::Types::Tuple then type.types.any? { |member| record_in?(member) }
        else false
        end
      end

      def receiver?(constr, node)
        constr.method_context&.value_uses&.receiver?(node) || false
      end

      # Whether nothing in the body takes the value of `node`.
      def left?(constr, node)
        constr.method_context&.value_uses&.left?(node) || false
      end

      # Whether something in the body takes the value of `node`.
      def taken?(constr, node)
        constr.method_context&.value_uses&.taken?(node) != false
      end

      def entered_ivar?(constr, name)
        def_node = constr.method_context&.node
        !def_node.nil? && (constr.specialization_arguments(def_node)&.self_ivars&.key?(name) || false)
      end

      # A reader answering what an object's state, or an ivar of `self` the
      # body was entered with, holds.
      def followed_read?(constr, call, node, receiver_type)
        return false unless call.is_a?(TypeInference::MethodCall::Typed) && node.children.size == 2

        state = ObjectStates.state_in(receiver_type) or return entered_ivar?(constr, ObjectStates::HeldIvar.self_ivar(constr, node))
        !ObjectStates.reader_ivar(constr, state, call).nil?
      end

      # `[holder, key]` where `node` reads `key` off the record a holder
      # keeps.
      def path(constr, node)
        return unless node.type == :send && node.children[1] == :[] && node.children.size == 3 && node.children[2].type == :sym

        holder = holder_of(constr, node.children[0]) or return
        [holder, node.children[2].children[0]]
      end

      # What `node` reads a followed record off: `[object, state, ivar]` for
      # a reader off a state, or an ivar of `self` the body was entered with.
      def holder_of(constr, node)
        state, ivar = read_off_state(constr, node)
        return [node.children[0], state, ivar] if state

        name = ObjectStates::HeldIvar.self_ivar(constr, node)
        name if name && entered_ivar?(constr, name) && constr.context.type_env[name].is_a?(AST::Types::Record)
      end

      def holder_record(constr, holder)
        holder.is_a?(Symbol) ? constr.context.type_env[holder] : holder[1].ivar_type(holder[2])
      end

      # `constr` with `holder` keeping `record`, where it is followed; and
      # what it keeps unknown otherwise, or where `record` is nil.
      def moved_holder(constr, holder, record)
        return ObjectStates::HeldIvar.refine(constr, holder, record || declared_hash(constr, holder)) if holder.is_a?(Symbol)

        object, state, ivar = holder
        left_holding(constr, object, state, ivar, (record if followed?(constr, object)))
      end

      def flattened(constr, holder)
        flat = flatten(holder_record(constr, holder))
        return ObjectStates::HeldIvar.refine(constr, holder, flat) if holder.is_a?(Symbol)

        object, state, ivar = holder
        left_holding(constr, object, state, ivar, flat)
      end

      # A store or `delete` on a record read by key off one a holder keeps:
      # the record moves in place.
      def written_along(constr, node, (holder, key), record, keys, arguments, type:)
        moved, answer = moved(constr, record, keys, arguments, fresh: false)
        outer = holder_record(constr, holder)
        placed = AST::Types::Record.new(elements: outer.elements.merge(key => moved), required_keys: outer.required_keys) if moved && outer.is_a?(AST::Types::Record)
        constr = moved_holder(constr, holder, placed)
        answer ? [answer, constr.add_typing(node, type: answer).constr] : [type, constr]
      end

      # Every followed variable here keeping a record in a record — a state's
      # ivar, an ivar the body was entered with — keeping it as its class.
      def forgotten(constr)
        env = constr.context.type_env
        constr = env.local_variable_types.each_key.reduce(constr) do |current, name|
          flat = flatten_states(env[name])
          flat.equal?(env[name]) ? current : ObjectStates.refine_local(current, name, flat)
        end
        env.instance_variable_types.each_key.reduce(constr) do |current, name|
          flat = entered_ivar?(constr, name) ? flatten(env[name]) : flatten_states(env[name])
          flat.equal?(env[name]) ? current : ObjectStates::HeldIvar.refine(current, name, flat)
        end
      end

      # A value read out of a record that keeps records, with each of those
      # as its class.
      def as_class(type)
        case type
        when AST::Types::Record then storable_value(type) || type
        when AST::Types::Union then AST::Types::Union.build(types: type.types.map { |member| as_class(member) })
        else type
        end
      end

      def flatten_states(type)
        case type
        when AST::Types::ObjectState then flatten(type)
        when AST::Types::Union, AST::Types::Intersection
          members = type.types.map { |member| flatten_states(member) }
          members.zip(type.types).all? { |flat, member| flat.equal?(member) } ? type : type.class.build(types: members)
        else type
        end
      end

      # A hash literal stored where nothing takes its value, as the record it
      # was written as.
      def fresh_record(constr, argument)
        record = argument&.type == :hash && Specializations::Arguments.written_record(argument, constr.typing, nil)
        record if record && record.elements.each_value.all? { |value| record_value?(value) }
      end
    end
  end
end
