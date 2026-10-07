module Steep
  module AST
    module Types
      # An instance whose ivars are KNOWN, because the call that built it fixed
      # them for good (felixefelip/steep#205, stage 1):
      #
      #   Reflection.new(:posts)   # ::Reflection{@name: :posts}
      #
      # A class type says what an object can do; this also says what it holds.
      # It is only ever built where the holding cannot change — an ivar that
      # `initialize` binds from an argument and nothing else in the project
      # writes (`Project::ConstructorBindingRegistry#immutable_ivar_bindings_for`),
      # set to a value that cannot change either — so a second name for the same
      # object, or a method it is handed to, sees the same value.
      #
      # RBS cannot spell it, and it leaves as the class wherever it is written
      # down. What it buys is the distance in between: a body specialized for the
      # object it was handed, whose reader answers the value.
      class ObjectState
        include NotInRBS

        # The class, as `Name::Instance`.
        attr_reader :back_type

        # `{ :@name => :posts }`, by ivar name.
        attr_reader :ivars

        def initialize(back_type:, ivars:)
          @back_type = back_type
          @ivars = ivars.sort_by { |name, _| name }.to_h
        end

        def ==(other)
          other.is_a?(ObjectState) && other.back_type == back_type && other.ivars == ivars
        end

        def hash
          self.class.hash ^ back_type.hash ^ ivars.hash
        end

        alias eql? ==

        def subst(s)
          self.class.new(back_type: back_type.subst(s), ivars: ivars.transform_values { |type| type.subst(s) })
        end

        # Unlike any RBS type, so a reader can tell the values are the answer and
        # not a declaration: the class, then what it holds.
        def to_s
          "#{back_type}{#{ivars.map { |name, type| "#{name}: #{type}" }.join(", ")}}"
        end

        def free_variables
          @fvs ||= each_child.with_object(::Set[]) do |type, set| #$ Set[variable]
            set.merge(type.free_variables)
          end
        end

        include Helper::ChildrenLevel

        def each_child(&block)
          types = [back_type, *ivars.values]
          if block
            types.each(&block)
          else
            types.each
          end
        end

        def map_type(&block)
          self.class.new(back_type: yield(back_type), ivars: ivars.transform_values(&block))
        end

        def level
          [0] + level_of_children([back_type, *ivars.values])
        end

        def with_location(new_location)
          self
        end

        # What the object holds in `name`, or nil where that is not known.
        def ivar_type(name)
          ivars[name]
        end
      end
    end
  end
end
