module Steep
  module Specializations
    # The class states a file's top level starts with: what the one file
    # defining each class left it holding (felixefelip/steep#589). A file other
    # than that one may or may not have run when a third one reads the class,
    # so a class such a file leaves holding something else than it entered
    # with is carried no further.
    class FileStates
      def initialize
        @by_path = {} #: Hash[Pathname, [Set[RBS::TypeName], Hash[RBS::TypeName, untyped], Hash[RBS::TypeName, untyped]]]
        @rewritten_elsewhere = Set[] #: Set[RBS::TypeName]
      end

      def record(path, typing)
        return unless typing.top_level_states

        entered, left = typing.top_level_states
        entered.each { |name, ivars| @rewritten_elsewhere << name unless left[name] == ivars }
        @by_path[path] = [typing.defined_classes, entered, left]
      end

      def entering
        definers = Hash.new { |hash, name| hash[name] = [] } #: Hash[RBS::TypeName, Array[Pathname]]
        @by_path.each { |path, (defined, _, _)| defined.each { |name| definers[name] << path } }
        @by_path.keys.to_h do |path|
          states = definers.filter_map do |name, (definer, *others)|
            next if others.any? || definer == path || @rewritten_elsewhere.include?(name)

            ivars = @by_path.fetch(definer)[2][name] and [name, ivars]
          end
          [path, states.to_h]
        end
      end

      # The files last checked entering with other states than they would now.
      def stale_paths = entering.filter_map { |path, states| path unless @by_path.fetch(path)[1] == states }
    end
  end
end
