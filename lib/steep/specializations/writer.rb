module Steep
  module Specializations
    class Writer
      def self.write(path, methods, declarations, receivers, exits)
        new(path, methods, declarations, receivers, exits).write
      end

      def initialize(path, methods, declarations, receivers, exits)
        @path = path
        @methods = methods
        @declarations = declarations
        @receivers = receivers
        @exits = exits
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
        payload["receivers"] = @receivers.sort.to_h { |site, types| [site, types.sort] } unless @receivers.empty?
        payload["exits"] = @exits.keys.sort.to_h { |key| [key, @exits[key].sort.to_h] } unless @exits.empty?
        payload
      end
    end
  end
end
