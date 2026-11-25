module Steep
  module Specializations
    # The type the checker gave the receiver of each call naming a reader, by
    # the call's site (`ClassMemoAnalyzer.site`). A use of a reader whose
    # receiver can be no value of a type says nothing of the object of that
    # type.
    module Receivers
      SENDS = %i[send csend].freeze

      class << self
        # Each call in `node` naming one of `names`, and each whose block
        # makes one (`ObjectStates::BlockRun.runs_in_place?`), with the
        # receiver's type as RBS: on `self`, the type `self` has where the
        # call is made (`call`, which a call with a block is recorded on). A
        # site whose receiver the checker did not type is nil; one it typed
        # but RBS cannot spell is nil too, and its type is kept in
        # `unwritten`.
        def collect(typing, node, names, unwritten:, found: {}, call: node)
          return found unless node.is_a?(::Parser::AST::Node)

          if SENDS.include?(node.type) && (names.include?(node.children[1]) || method_object?(node, names)) && (site = TypeInference::ClassMemoAnalyzer.site(node))
            found[site] = receiver_written(typing, node.children[0], call, site, unwritten)
          end
          if Accumulators::LAMBDA_BODIES.include?(node.type) && SENDS.include?(node.children[0].type) && names_any?(node.children.drop(1), names) &&
             (site = TypeInference::ClassMemoAnalyzer.site(node.children[0]))
            found[site] = receiver_written(typing, node.children[0].children[0], node, site, unwritten)
          end
          node.children.each_with_index do |child, index|
            collect(typing, child, names, unwritten: unwritten, found: found, call: Accumulators::LAMBDA_BODIES.include?(node.type) && index.zero? ? node : child)
          end
          found
        end

        # Adds what `collect` found to `receivers`: a site read by two targets
        # keeps what both typed it as, and one a target could not type is
        # `untyped` for good (`unknown`).
        def record(receivers, unknown, found)
          found.each do |site, type|
            if type.nil? || unknown.include?(site)
              unknown << site
              receivers[site] = Record::UNTYPED
            else
              receivers[site] = receivers.fetch(site, []) | [type]
            end
          end
        end

        # The uses of `name` whose receiver may be a value of `target`.
        def uses_on(constr, name, target, every: false)
          registry = constr.constructor_bindings
          (every ? registry.every_use_of(name) : registry.uses_of(name)).reject { |use| elsewhere?(constr, use, target) }
        end

        # The calls of `name` whose receiver may be a value of `target`
        # (`ConstructorBindingRegistry#calls_of`).
        def calls_on(constr, name, target)
          registry = constr.constructor_bindings
          constr.specializations.keep([:calls_on, constr.checker, registry, name, target]) do
            registry.calls_of(name).reject { |call| elsewhere?(constr, call, target) }.freeze
          end
        end

        # Whether `call` may run one of the methods of the project's it names
        # that `owners` define (`ConstructorBindingRegistry#owners_of`): its
        # receiver may be a value of one of them. A receiver typed `untyped`
        # is taken as none of them.
        def reaches?(constr, call, owners)
          owners.empty? || owners.any? do |class_name, singleton|
            name = RBS::TypeName.parse("::#{class_name}")
            target = singleton ? AST::Types::Name::Singleton.new(name: name) : AST::Types::Name::Instance.new(name: name, args: [])
            !elsewhere?(constr, call, target)
          end
        end

        private

        def method_object?(node, names)
          name = node.children[2]
          TypeInference::ClassMemoAnalyzer::METHOD_OBJECTS.include?(node.children[1]) && %i[sym str].include?(name&.type) && names.include?(name.children[0].to_sym)
        end

        def names_any?(nodes, names)
          nodes.any? do |node|
            node.is_a?(::Parser::AST::Node) && ((SENDS.include?(node.type) && names.include?(node.children[1])) || names_any?(node.children, names))
          end
        end

        def receiver_written(typing, receiver, call, site, unwritten)
          self_type = typing.self_type_of_call(node: call)
          type = receiver.nil? || receiver.type == :self ? self_type : (typing.type_of(node: receiver) if typing.has_type?(receiver))
          return unless type

          written(type, self_type).tap { |spelled| unwritten[site] = type.to_s unless spelled }
        end

        def written(type, self_type)
          type = classes_only(Specializations.rbs_writable(readable(type)).subst(placed(self_type)))
          type.to_s if type.free_variables.empty?
        end

        # `self` and `instance` as the call they were typed at was checked
        # under.
        def placed(self_type)
          instance = instance_of(self_type)
          Interface::Substitution.build(
            [], [],
            self_type: self_type || AST::Types::Self.instance,
            instance_type: instance || AST::Types::Instance.instance,
            module_type: (instance && singleton_of(instance)) || AST::Types::Class.instance
          )
        end

        def instance_of(type)
          case type
          when AST::Types::Name::Singleton then AST::Types::Name::Instance.new(name: type.name, args: [])
          when AST::Types::Name::Instance then type
          when AST::Types::Union then type.types.map { |member| instance_of(member) or return nil }.then { |members| AST::Types::Union.build(types: members) }
          end
        end

        def singleton_of(type)
          case type
          when AST::Types::Name::Instance then AST::Types::Name::Singleton.new(name: type.name)
          when AST::Types::Union then type.types.map { |member| singleton_of(member) or return nil }.then { |members| AST::Types::Union.build(types: members) }
          end
        end

        # What a value of a class may be depends neither on the class's
        # parameters nor, for a proc, on its signature. A type variable may be
        # a value of any class.
        def classes_only(type)
          case type
          when AST::Types::Proc then AST::Builtin::Proc.instance_type
          when AST::Types::Var then AST::Builtin::BasicObject.instance_type
          when AST::Types::Name::Instance, AST::Types::Name::Interface
            variables = type.free_variables.grep(Symbol)
            type.subst(Interface::Substitution.build(variables, variables.map { AST::Builtin.any_type }))
          else type.map_type { |child| classes_only(child) }
          end
        end

        def readable(type)
          type.is_a?(AST::Types::Logic::Base) ? AST::Builtin.bool_type : type.map_type { |child| readable(child) }
        end

        def elsewhere?(constr, use, target)
          factory = constr.checker.factory
          type = receiver_of(constr, use) or return false
          return true if AST::Types::Union.used_as_untyped?(type)

          target = factory.instance_type(target.name) if target.is_a?(AST::Types::Name::Instance)
          interpreter = TypeInference::LogicTypeInterpreter.new(subtyping: constr.checker, typing: constr.typing, config: constr.builder_config)
          interpreter.type_case_select0(type, target)[0].empty?
        rescue RBS::BaseError, RuntimeError
          false
        end

        def receiver_of(constr, use)
          factory = constr.checker.factory
          site = use.at || use.self_at
          return constr.specializations.receiver_type(site, factory: factory) if site
          return if use.kind != :escape || use.owner.to_s.empty?

          name = RBS::TypeName.parse("::#{use.owner}")
          factory.instance_type(name) if factory.definition_builder.env.module_class_entry(name)
        end
      end

      # What a run recorded of the receivers: the whole-file checks', and the
      # specialized checks' of each body. `receivers` is what a store reads: the
      # whole-file record, with a site it left unknown or `untyped` filled in
      # from the specialized checks of its body, when a tuple covers every call
      # of the body and every one of them typed the site. Where some call fixes
      # nothing (`untupled`), the declaration is all that types the body's
      # parameters; where a check left the site untyped (a branch its tuple
      # does not take, a receiver typed relative to the caller), it says
      # nothing the whole file did not.
      class Record
        UNTYPED = ["untyped"].freeze

        # `unwritten`: the type of each site the checker typed but RBS cannot
        # spell (`Receivers.collect`).
        attr_reader :receivers, :unwritten

        def initialize
          @receivers = {} #: Hash[String, Array[String]]
          @unwritten = {} #: Hash[String, String]
          @whole = {} #: Hash[String, Array[String]]
          @unknown = Set[] #: Set[String]
          @received = {} #: Hash[String, Array[Hash[String, String?]]]
          @untupled = Set[] #: Set[String]
        end

        def untupled(key) = @untupled << key

        # The sites whose receiver the checker typed but the record holds as
        # `untyped`, with that type (`Receivers.reaches?`).
        def unrecorded = @unwritten.select { |site, _| @receivers.fetch(site, UNTYPED) == UNTYPED }

        def record(found)
          Receivers.record(@whole, @unknown, found)
          adopt({})
        end

        # `received`: what a generation's specialized checks found in each
        # body, one per tuple. Whether `receivers` moved.
        def adopt(received)
          @received.merge!(received)
          receivers = @whole.transform_values(&:dup)
          @received.each do |key, founds|
            next if @untupled.include?(key)

            founds.flat_map(&:keys).uniq.each do |site|
              next unless receivers.fetch(site, UNTYPED) == UNTYPED

              types = founds.map { |found| found[site] }
              receivers[site] = types.uniq unless types.include?(nil)
            end
          end
          return false if receivers == @receivers

          @receivers.replace(receivers)
          true
        end
      end
    end
  end
end
