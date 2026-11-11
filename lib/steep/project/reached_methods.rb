module Steep
  class Project
    # The methods `table` holds for a class, but those it defines only in a
    # branch its class body never takes (`Postconditions::UnreachedDefinitions`),
    # read once per class for each set of definitions ruled out.
    class ReachedMethods
      def initialize(table, separator)
        @table = table
        @separator = separator
        @by_unreached = {}.compare_by_identity #: Hash[Set[String], Hash[untyped, Hash[Symbol, Array[TypeInference::ConstructorBindingAnalyzer::Body?]]]]
      end

      def of(class_name, unreached)
        (@by_unreached[unreached] ||= {})[class_name] ||= begin
          name = class_name.to_s.delete_prefix("::")
          methods = @table[name] || {}
          unreached.empty? ? methods : methods.reject { |method_name, _| unreached.include?("#{name}#{@separator}#{method_name}") }
        end
      end

      def clear = @by_unreached.clear
    end
  end
end
