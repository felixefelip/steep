module Steep
  module TypeInference
    # Where the project may set a class variable, for a memo of one
    # (`@@x ||= Klass.new`) to tell whether it is the only code that does.
    module ClassVariableWrites
      class << self
        # Adds to `index`, under each of `names`, the class variables `body`, a
        # class or module body, assigns anything but `nil` outside its methods.
        def record_class_body(index, names, body)
          written = in_class_body(body, Set[])
          names.each { |name| (index[name] ||= Set[]).merge(written) } unless written.empty?
        end

        # `[class name, method name, memo]` for each method of `tables` that
        # assigns one of `cvars`, or any class variable without them, `memo`
        # where by `||=`, and each class body of `class_bodies`
        # (`{ class name => cvars }`) that does, with no method name.
        def of(tables, class_bodies, cvars)
          found = [] #: Array[[String, Symbol?, bool]]
          tables.each do |table|
            table.each do |class_name, methods|
              methods.each do |name, bodies|
                bodies.compact.each do |body|
                  found << [class_name, name, false] if names?(body.cvar_writes, cvars)
                  found << [class_name, name, true] if names?(body.cvar_memos, cvars)
                end
              end
            end
          end
          class_bodies.each { |class_name, written| found << [class_name, nil, false] if names?(written, cvars) }
          found
        end

        private

        def in_class_body(node, written)
          return written unless node.is_a?(::Parser::AST::Node) && !%i[def defs class module].include?(node.type)

          written << node.children[0] if node.type == :cvasgn && node.children[1]&.type != :nil
          node.children.each { |child| in_class_body(child, written) }
          written
        end

        def names?(written, cvars) = cvars ? written.intersect?(cvars) : !written.empty?
      end
    end
  end
end
