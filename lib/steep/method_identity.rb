module Steep
  # The one core method a call resolved to, spelled as the key both intrinsic
  # tables are written against (`::Array#join`, `::Module#instance_method`).
  #
  # One identity or nothing: a call whose declarations name more than one method
  # has no single implementation to reason about, and a table entry found under
  # either name would be answering for a call site that might run the other.
  module MethodIdentity
    def self.key(call)
      names = call.method_decls.map { |decl| decl.method_name.to_s }.uniq
      return nil unless names.size == 1

      normalize(names.first)
    end

    # Every method a call of `method_name` on `type` may resolve to, keyed this
    # way. Empty for one `type` does not have.
    def self.keys(constr, type, method_name, private:)
      interface = constr.calculate_interface(type, private: private) or return []
      method = interface.methods[method_name] or return []

      method.overloads.flat_map { |overload| overload.method_decls(method_name) }.map { |decl| normalize(decl.method_name.to_s) }.uniq
    end

    def self.normalize(name)
      string = name.to_s
      string.start_with?("::") ? string : "::#{string}"
    end
  end
end
