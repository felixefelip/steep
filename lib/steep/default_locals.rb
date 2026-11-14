module Steep
  # The locals an optional parameter's default assigns, as MRI's hash.rb
  # writes `def initialize(ifnone = (ifnone_unset = true), …)`: set where the
  # default runs, and nil where the call passed the parameter, which a body
  # checked for one call's arguments knows.
  module DefaultLocals
    def self.settled(constr, param)
      names = assigned(param.children[1])
      return constr if names.empty?

      passed = passed?(constr, param)
      constr.update_type_env do |env|
        names.reduce(env) do |left, name|
          type = left[name] or next left
          settled = if passed.nil?
                      AST::Types::Union.build(types: [type, AST::Builtin.nil_type])
                    else
                      passed ? AST::Builtin.nil_type : type
                    end
          left.assign_local_variable(name, settled, nil)
        end
      end
    end

    def self.assigned(node)
      return [] unless node.is_a?(Parser::AST::Node)

      [*(node.children[0] if node.type == :lvasgn), *node.children.flat_map { |child| assigned(child) }]
    end

    # Whether the call the body is checked for passed `param`; nil where the
    # body is not checked for one call.
    def self.passed?(constr, param)
      def_node = constr.method_context&.node or return nil
      arguments = constr.specialization_arguments(def_node) or return nil
      return arguments.keywords.key?(param.children[0]) if param.type == :kwoptarg

      args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
      index = args.children.take_while { |arg| !arg.equal?(param) }.count { |arg| %i[arg optarg].include?(arg.type) }
      arguments.positionals.size > index
    end
  end
end
