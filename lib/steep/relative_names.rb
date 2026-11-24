module Steep
  # A type name spelled without its leading `::`, as the registries and the
  # sidecars key classes.
  module RelativeNames
    NAMES = {} #: Hash[RBS::TypeName | String, String]

    def self.of(name)
      NAMES[name] ||= name.to_s.delete_prefix("::").freeze
    end
  end
end
