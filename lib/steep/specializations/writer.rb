module Steep
  module Specializations
    class Writer
      def self.write(path, methods, declarations)
        new(path, methods, declarations).write
      end

      def initialize(path, methods, declarations)
        @path = path
        @methods = methods
        @declarations = declarations
      end

      def write
        @path.parent.mkpath
        @path.write(YAML.dump(payload))
        @path
      end

      private

      def payload
        payload = {
          "version" => SCHEMA_VERSION,
          "methods" => @methods.keys.sort.to_h { |key| [key, @methods[key].sort.to_h] }
        } #: Hash[String, untyped]
        payload["declarations"] = @declarations.sort.to_h unless @declarations.empty?
        payload
      end
    end
  end
end
