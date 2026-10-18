module Steep
  # A record a held record keeps under a key, one level down
  # (felixefelip/steep#314):
  #
  #   foo.my_hash[:bar] = { num1: 5, num2: 10 }   # @my_hash: { bar: { num1: 5, num2: 10 } }
  #   foo.my_hash[:bar][:num2] = 30               # @my_hash: { bar: { num1: 5, num2: 30 } }
  #
  # It is born of a literal stored through a followed path where nothing in
  # the body takes the store's value (`TypeInference::ValueUses`), and stays a
  # record while every read of it is a step of such a path. Read anywhere
  # else, it may get a second name, so from there on it is held as its class,
  # in the answer and in what holds it.
  module HashMutation
    class << self
      # A value a followed record may hold under a key.
      def held_value?(type)
        record_value?(type) || (type.is_a?(AST::Types::Record) && type.elements.each_value.all? { |value| record_value?(value) })
      end

      # `type` with every record a record holds held as its class.
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

      # A hash whose record keeps one, answered anywhere but a step, comes
      # out with it held as its class: `answer_taken` makes every holder
      # forget it, and the name it gets has to agree.
      def handed_out(call, node, constr)
        type = call.return_type
        type.is_a?(AST::Types::Record) && nested_in?(type) && !step?(constr, node) ? call.with_return_type(flatten(type)) : call
      end

      # Once a call is done, one whose answer holds a record something in the
      # body takes may have handed out one a state keeps, so every variable
      # here forgets them.
      def answer_taken(constr, node)
        return constr unless taken?(constr, node) && !step?(constr, node)

        call = ObjectStates.recorded_call(constr, node)
        call && record_in?(call.return_type) ? forgotten(constr) : constr
      end

      # `@ivar` read anywhere but a step.
      def read_ivar(constr, node, type)
        return constr.add_typing(node, type: type) unless type.is_a?(AST::Types::Record) && nested_in?(type) && !step?(constr, node)

        ObjectStates::HeldIvar.refine(constr, node.children[0], flatten(type)).add_typing(node, type: flatten(type))
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

      def step?(constr, node)
        constr.method_context&.value_uses&.step?(node) || false
      end

      # Whether something in the body takes the value of `node`.
      def taken?(constr, node)
        constr.method_context&.value_uses&.kept?(node) != false
      end

      # `[holder, key]` where `node` reads `key` off the record a holder
      # keeps: a reader off a state, or an ivar of `self` the body was
      # entered with.
      def path(constr, node)
        return unless node.type == :send && node.children[1] == :[] && node.children.size == 3 && node.children[2].type == :sym

        holder = holder_of(constr, node.children[0]) or return
        [holder, node.children[2].children[0]]
      end

      def holder_of(constr, node)
        state, ivar = read_off_state(constr, node)
        return [node.children[0], state, ivar] if state

        name = ObjectStates::HeldIvar.self_ivar(constr, node)
        def_node = constr.method_context&.node
        name if name && def_node && constr.specialization_arguments(def_node)&.self_ivars&.key?(name) && constr.context.type_env[name].is_a?(AST::Types::Record)
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

      # A store or `delete` on a record read by key off one a holder keeps:
      # the record moves in place.
      def written_along(constr, node, (holder, key), record, keys, arguments, type:)
        moved, answer = moved(constr, record, keys, arguments, fresh: false)
        outer = holder_record(constr, holder)
        placed = AST::Types::Record.new(elements: outer.elements.merge(key => moved), required_keys: outer.required_keys) if moved && outer.is_a?(AST::Types::Record)
        constr = moved_holder(constr, holder, placed)
        answer ? [answer, constr.add_typing(node, type: answer).constr] : [type, constr]
      end

      # Every variable here keeping a record in a record, keeping it as its
      # class.
      def forgotten(constr)
        env = constr.context.type_env
        constr = env.local_variable_types.each_key.reduce(constr) do |current, name|
          nested_in?(env[name]) ? ObjectStates.refine_local(current, name, flatten(env[name])) : current
        end
        env.instance_variable_types.each_key.reduce(constr) do |current, name|
          nested_in?(env[name]) ? ObjectStates::HeldIvar.refine(current, name, flatten(env[name])) : current
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
