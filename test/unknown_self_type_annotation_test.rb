require_relative "test_helper"

# felixefelip/steep#101. A body annotated `@type self:` / `@type self_method:` naming a
# type the environment does not declare used to reach `RBS::DefinitionBuilder#build_instance`,
# which answers an unknown name with a bare RuntimeError — killing the whole run rather
# than the one file, and naming a class the user typically never wrote (the ERB convention
# annotates a template with `ERBFoo`, generated code whose RBS may not exist yet).
class UnknownSelfTypeAnnotationTest < Minitest::Test
  include Steep
  include TestHelper
  include ShellHelper

  def dirs
    @dirs ||= []
  end

  STEEPFILE = <<~STEEPFILE
    target :app do
      signature "sig"
      check "app"
    end
  STEEPFILE

  RBS = <<~RBS
    class Widget
      def size: () -> Integer
    end
  RBS

  def type_check_source(ruby)
    in_tmpdir do
      (current_dir + "sig").mkpath
      (current_dir + "app").mkpath
      (current_dir + "sig/widget.rbs").write(RBS)
      (current_dir + "app/body.rb").write(ruby)
      (current_dir + "Steepfile").write(STEEPFILE)

      project = Project.new(steepfile_path: current_dir + "Steepfile")
      Project::DSL.parse(project, STEEPFILE)
      target = project.targets.first

      loader = Project::Target.construct_env_loader(options: target.options, project: project)
      file_loader = Services::FileLoader.new(base_dir: project.base_dir)
      file_loader.each_path_in_patterns(target.signature_pattern) do |path|
        absolute = project.absolute_path(path)
        loader.add(path: absolute) if absolute.file?
      end
      status = Services::SignatureService.load_from(loader, implicitly_returns_nil: target.implicitly_returns_nil).status

      absolute = project.absolute_path(Pathname("app/body.rb"))
      source = Steep::Source.parse(absolute.read, path: absolute, factory: status.subtyping.factory)

      yield Services::TypeCheckService.type_check(
        source: source,
        subtyping: status.subtyping,
        constant_resolver: status.constant_resolver,
        cursor: nil,
        contracts: project.contracts,
        postconditions: project.postconditions,
        callbacks: project.callbacks,
        delegation_registry: project.delegation_registry,
        constructor_bindings: project.constructor_binding_registry,
        return_forwarding: project.return_forwarding_registry,
        return_alias: project.return_alias_registry
      )
    end
  end

  def test_reports_instead_of_raising
    typing = nil
    type_check_source(<<~RUBY) { |t| typing = t }
      # @type self_method: ERBNeverDeclared#__rbs_infer__body
      1 + 1
    RUBY

    error = typing.errors.find { |e| e.is_a?(Diagnostic::Ruby::UnknownSelfTypeAnnotation) }
    refute_nil error, "expected the undeclared self type to be reported"
    assert_equal "::ERBNeverDeclared", error.name.to_s
    assert_match(/Cannot find the declaration of the annotated self type/, error.header_line)
  end

  def test_checks_the_body_with_object_self
    # Falling back to `Object` is what the no-annotation case already does, so the rest of
    # the body is still checked — the file degrades, it does not stop being analyzed.
    typing = nil
    type_check_source(<<~RUBY) { |t| typing = t }
      # @type self_method: ERBNeverDeclared#__rbs_infer__body
      widget = Widget.new
      widget.no_such_method
    RUBY

    assert typing.errors.any? { |e| e.is_a?(Diagnostic::Ruby::NoMethod) },
           "the body is still type-checked under the fallback self"
  end

  def test_a_declared_self_type_is_untouched
    typing = nil
    type_check_source(<<~RUBY) { |t| typing = t }
      # @type self_method: Widget#size
      size
    RUBY

    assert_empty typing.errors.select { |e| e.is_a?(Diagnostic::Ruby::UnknownSelfTypeAnnotation) }
    assert_empty typing.errors, "`size` resolves because self really is Widget"
  end
end
