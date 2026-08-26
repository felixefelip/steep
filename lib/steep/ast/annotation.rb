module Steep
  module AST
    module Annotation
      module Located
        attr_reader :location

        def line
          location&.start_line
        end
      end

      class Named
        include Located

        attr_reader :name
        attr_reader :type

        def initialize(name:, type:, location: nil)
          @name = name
          @type = type
          @location = location
        end

        def ==(other)
          other.is_a?(self.class) &&
            other.name == name &&
            other.type == type
        end
      end

      class Typed
        include Located

        attr_reader :type

        def initialize(type:, location: nil)
          @type = type
          @location = location
        end

        def ==(other)
          other.is_a?(self.class) &&
            other.type == type
        end
      end

      class ReturnType < Typed; end
      class BlockType < Typed; end
      class SelfType < Typed; end
      class InstanceType < Typed; end

      # `@type self_method: Klass#method` — like `SelfType` (binds `self` to an
      # instance of `Klass`) but ALSO names a method whose entry facts apply to
      # this top-level body. Used for a body checked outside a `def` that at
      # runtime IS a method (an ERB view template compiled to a method): the
      # annotation carries the `Klass#method` identity so the method-entry-fact
      # machinery can narrow reads in it, without physically wrapping the source
      # in a `def` (which would shift line positions).
      class SelfMethod
        include Located

        attr_reader :type
        attr_reader :method_name

        def initialize(type:, method_name:, location: nil)
          @type = type
          @method_name = method_name
          @location = location
        end

        def ==(other)
          other.is_a?(self.class) && other.type == type && other.method_name == method_name
        end
      end
      class ModuleType < Typed; end
      class BreakType < Typed; end

      class MethodType < Named; end
      class VarType < Named; end
      class ConstType < Named; end
      class IvarType < Named; end

      class Implements
        class Module
          attr_reader :name
          attr_reader :args

          # Whether the annotation names the class object's method table rather
          # than its instances' — `@implements singleton(::Foo)` against
          # `@implements ::Foo`.
          #
          # One name and a flag, rather than a type: `@implements` says which
          # DEFINEE a body has, and Ruby gives a class exactly two. A block
          # replayed with `Foo.singleton_class.class_eval` defines `Foo.bar`, and
          # that is the whole of what this distinguishes
          # (felixefelip/steep#152).
          def initialize(name:, args:, singleton: false)
            @name = name
            @args = args
            @singleton = singleton
          end

          def singleton?
            @singleton
          end

          def ==(other)
            other.is_a?(Module) && other.name == name && other.args == args &&
              other.singleton? == singleton?
          end

          alias eql? ==

          def hash
            self.class.hash ^ name.hash ^ args.hash ^ singleton?.hash
          end
        end

        include Located

        # Every module the annotation names, in the order written.
        #
        # A LIST, because one block body can be run against several modules and
        # `class_eval` is how: a block kept in one place and replayed onto two
        # classes defines its methods on both, so `# @implements A, B` is the
        # only honest thing to write over it. Writing two separate `@implements`
        # comments cannot say it — an annotation rides the block's opener line,
        # and a second `#` on that line lands inside the first one's text
        # (felixefelip/steep#149).
        attr_reader :names

        # The first, which is what a CLASS or MODULE body means by the
        # annotation: a `class X` has one definee no matter how many names are
        # written, so the rest are ignored there and only a block reads them all.
        attr_reader :name

        def initialize(names:, location: nil)
          raise ArgumentError, "@implements needs at least one module" if names.empty?

          @location = location
          @names = names
          @name = names.first
        end

        def ==(other)
          other.is_a?(Implements) && other.names == names
        end
      end

      class Dynamic
        class Name
          attr_reader :kind
          attr_reader :name
          attr_reader :location

          def initialize(name:, kind:, location: nil)
            @name = name
            @kind = kind
            @location = location
          end

          def instance_method?
            kind == :instance || kind == :module_instance
          end

          def module_method?
            kind == :module || kind == :module_instance
          end

          def ==(other)
            other.is_a?(Name) &&
              other.name == name &&
              other.kind == kind
          end
        end

        include Located

        attr_reader :names

        def initialize(names:, location: nil)
          @location = location
          @names = names
        end

        def ==(other)
          other.is_a?(Dynamic) &&
            other.names == names
        end
      end
    end
  end
end
