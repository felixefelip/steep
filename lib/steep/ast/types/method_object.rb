module Steep
  module AST
    module Types
      # A method object that remembers WHICH method it is.
      #
      #   Foo.instance_method(:bar)          # unbound_method(::Foo#bar)
      #   Foo.singleton_class
      #      .public_instance_method(:bar)   # unbound_method(::Foo.bar)
      #   foo.method(:bar)                   # method(::Foo#bar)
      #
      # Without it, `::UnboundMethod` is all a reflection answers, and a
      # question about the method it reflects — `#parameters`, which is what
      # `ActiveSupport::Delegation` asks — has nothing left to read
      # (felixefelip/steep#171).
      #
      # It carries NAMES, not a definition: the environment behind them can be
      # rebuilt, and a type that held a definition would outlive it. What the
      # method is, is looked up at the question that needs it.
      #
      # A leaf, like `Literal`, answering everything else as the `::Method` or
      # `::UnboundMethod` it is one of.
      class MethodObject
        attr_reader :type_name

        attr_reader :method_name

        # Which side of the module the method lives on: `true` for a class
        # method, `false` for an instance method.
        attr_reader :singleton

        # `::UnboundMethod` rather than `::Method` — the two are the same
        # question with a different receiver, and nothing here depends on the
        # difference but the class it widens to.
        attr_reader :unbound

        def initialize(type_name:, method_name:, singleton:, unbound:)
          @type_name = type_name
          @method_name = method_name
          @singleton = singleton
          @unbound = unbound
        end

        def ==(other)
          other.is_a?(MethodObject) &&
            other.type_name == type_name &&
            other.method_name == method_name &&
            other.singleton == singleton &&
            other.unbound == unbound
        end

        def hash
          self.class.hash ^ type_name.hash ^ method_name.hash ^ singleton.hash ^ unbound.hash
        end

        alias eql? ==

        def subst(s)
          self
        end

        def to_s
          "#{unbound ? "unbound_method" : "method"}(#{type_name}#{singleton ? "." : "#"}#{method_name})"
        end

        include Helper::NoFreeVariables

        include Helper::NoChild

        def level
          [0]
        end

        def with_location(new_location)
          self
        end

        def with(type_name: self.type_name, method_name: self.method_name, singleton: self.singleton, unbound: self.unbound)
          self.class.new(type_name: type_name, method_name: method_name, singleton: singleton, unbound: unbound)
        end

        def back_type
          if unbound
            AST::Builtin::UnboundMethod.instance_type
          else
            AST::Builtin::Method.instance_type
          end
        end
      end
    end
  end
end
