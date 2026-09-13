module Steep
  module Specializations
    class Writer
      def self.write(path, methods)
        new(path, methods).write
      end

      def initialize(path, methods)
        @path = path
        @methods = methods
      end

      def write
        @path.parent.mkpath
        @path.write(YAML.dump(payload))
        @path
      end

      private

      def payload
        {
          "version" => SCHEMA_VERSION,
          "methods" => @methods.keys.sort.to_h { |key| [key, @methods[key].sort.to_h] }
        }
      end
    end
  end
end
