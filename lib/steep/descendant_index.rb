module Steep
  # Which classes inherit from which, in the closed world an environment
  # describes.
  #
  # A nominal type names a class and the value it describes may be an instance —
  # or a class OBJECT — of any subclass of it: `singleton(::Sub)` is a
  # `singleton(::Base)`, so a receiver typed as the second may be the first. Most
  # questions survive that, because an override answers the supertype's
  # signature. One does not: what a method's parameter list IS, which is what a
  # reflection asks (felixefelip/steep#171).
  #
  # Reading the subclasses is what settles it, and only a whole-program view can:
  # a signature says what a class inherits, never what inherits from it.
  #
  # Classes only. A module is not subclassed, and a class that includes one is
  # not one of it — `M.instance_method(:x)` reflects M's own whatever includes M.
  class DescendantIndex
    def initialize(env)
      @children = build(env)
      @descendants = {}
    end

    # Every class below `name`, transitively, or nil when there are more than
    # `limit` of them — a bound on the work, and a question this will not spend
    # more than that answering.
    def descendants(name, limit:)
      key = [name, limit]
      cached = @descendants.fetch(key, :none)
      return cached unless cached == :none

      @descendants[key] = walk(name, limit)
    end

    private

    def walk(name, limit)
      found = Set[] #: Set[RBS::TypeName]
      queue = children_of(name).dup

      until queue.empty?
        child = queue.shift or raise
        next unless found.add?(child)
        return nil if found.size > limit

        queue.concat(children_of(child))
      end

      found.to_a
    end

    def children_of(name)
      @children.fetch(name, [])
    end

    # A class with no `super_class` written is a subclass of `Object`, which is
    # what makes `descendants(::Object)` the whole program — and, past the
    # limit, an answer this declines rather than computes.
    def build(env)
      children = {} #: Hash[RBS::TypeName, Array[RBS::TypeName]]

      env.class_decls.each do |name, entry|
        entry.each_decl do |decl|
          next unless decl.is_a?(RBS::AST::Declarations::Class)

          parent = decl.super_class&.name || RBS::BuiltinNames::Object.name
          next if parent == name

          (children[parent] ||= []) << name
        end
      end

      children.each_value(&:uniq!)
      children
    end
  end
end
