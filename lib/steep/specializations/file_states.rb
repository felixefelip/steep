module Steep
  module Specializations
    # The class states a file's top level starts with: what the one file
    # defining each class left it holding (felixefelip/steep#589). A file other
    # than that one may or may not have run when a third one reads the class,
    # so a class such a file leaves holding something else than it entered
    # with is carried no further.
    class FileStates
      def initialize
        @by_path = {} #: Hash[Pathname, [Set[RBS::TypeName], Hash[RBS::TypeName, untyped], Hash[RBS::TypeName, untyped], Set[String]]]
        @rewritten_elsewhere = Set[] #: Set[RBS::TypeName]
      end

      # A check of only some of a file's bodies skips the ones no call
      # specializes, which enter with the file's states too: the file stays
      # recorded as entered by the last check that ran them all.
      def record(path, typing, whole:)
        return unless typing.top_level_states

        entered, left, loaded = typing.top_level_states
        entered.each { |name, ivars| @rewritten_elsewhere << name unless left[name] == ivars }
        observed = typing.observed_classes
        if !whole && (_, last_entered, _, last_observed, last_loaded = @by_path[path])
          entered = last_entered
          loaded = last_loaded
          observed |= last_observed
        end
        @by_path[path] = [typing.defined_classes, entered, left, observed, loaded, typing.coded_classes]
      end

      # `states` of the classes in `names` (`ObjectStates::ClassStates.observed`).
      def self.among(states, names) = states.select { |name, _| names.include?(name.to_s.delete_prefix("::")) }

      def entering
        loaded = self.loaded
        @by_path.to_h { |path, (defined, _, _)| [path, loaded.reject { |name, _| defined.include?(name) }] }
      end

      # What the program's load leaves each class holding: what the one file
      # defining it left it holding, where no other file's top level changes it.
      # A file whose bodies of the class only define methods and mix in inert
      # modules defines it only where no file runs code in it.
      def loaded
        definers = Hash.new { |hash, name| hash[name] = [] } #: Hash[RBS::TypeName, Array[Pathname]]
        coders = Hash.new { |hash, name| hash[name] = [] } #: Hash[RBS::TypeName, Array[Pathname]]
        @by_path.each do |path, (defined, _, _, _, _, coded)|
          defined.each { |name| definers[name] << path }
          coded.each { |name| coders[name] << path }
        end
        definers.filter_map do |name, paths|
          definer, *others = coders.key?(name) ? coders[name] : paths
          next if others.any? || @rewritten_elsewhere.include?(name)

          ivars = @by_path.fetch(definer)[2][name] and [name, ivars]
        end.to_h
      end

      # The files last checked entering, or with their methods starting, with
      # other states than they would now, of the classes that check observed.
      def stale_paths
        loaded = self.loaded
        entering.filter_map do |path, states|
          _, entered, _, observed, last_loaded = @by_path.fetch(path)
          path unless FileStates.among(entered, observed) == FileStates.among(states, observed) && FileStates.among(last_loaded, observed) == FileStates.among(loaded, observed)
        end
      end
    end
  end
end
