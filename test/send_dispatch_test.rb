require_relative "test_helper"

# felixefelip/steep#137. `send` with a literal name IS a call to that method: the
# receiver's type is known and the name is right there, so the only thing the spelling
# adds over `recv.name(...)` is that it ignores visibility. Everything inside it used to
# be unchecked, because `send` returns `untyped`.
#
# Checked against the REAL core RBS rather than the stub environment the unit harness
# builds, because the feature turns on which core types declare these: `__send__` on
# `BasicObject`, `send` as `Kernel`'s alias of it, `public_send` on `Kernel`. A stub
# would let a wrong owner set pass.
class SendDispatchTest < Minitest::Test
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
    class SendTarget
      def title: () -> String

      def with_arg: (String value) -> Integer

      def each_word: () { (String) -> void } -> void

      private

      def secret: () -> Integer
    end

    # A method of the receiver's OWN called `send`, like `Ractor#send` or a socket's: its
    # first argument is a value, not a method name.
    class Bus
      def send: (Symbol channel, String payload) -> bool
    end
  RBS

  def type_check_source(ruby)
    in_tmpdir do
      (current_dir + "sig").mkpath
      (current_dir + "app").mkpath
      (current_dir + "sig/target.rbs").write(RBS)
      (current_dir + "app/body.rb").write(ruby)
      (current_dir + "Steepfile").write(STEEPFILE)

      project = Project.new(steepfile_path: current_dir + "Steepfile")
      Project::DSL.parse(project, STEEPFILE)
      target = project.targets.first or raise

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

  def errors_in(ruby)
    typing = nil #: Typing?
    type_check_source(ruby) { |t| typing = t }
    (typing or raise).errors.reject { |error| error.is_a?(Diagnostic::Ruby::UndeclaredMethodDefinition) }
  end

  # The return type comes from the method the literal names, so a wrong call on the result
  # is reported against THAT method's return type — which is the whole difference from
  # `untyped`.
  def test_resolves_the_method_the_literal_names
    errors = errors_in(<<~RUBY)
      SendTarget.new.send(:title).no_such_method_on_the_result
    RUBY

    assert_equal 1, errors.size
    errors[0].tap do |error|
      assert_instance_of Diagnostic::Ruby::NoMethod, error
      assert_equal "::String", error.type.to_s
      assert_equal :no_such_method_on_the_result, error.method
    end
  end

  # `send`/`__send__` ignore visibility — that is what they are for, and what MRI relies on
  # when `rb_funcall` invokes `append_features`/`included`, both private on `Module`.
  def test_reaches_a_private_method
    assert_empty errors_in(<<~RUBY)
      SendTarget.new.send(:secret) + 1
    RUBY
  end

  # `public_send` respects visibility, so this is a `NoMethodError` at runtime even though
  # the name resolves. A different situation from "no such method", and a different message.
  def test_public_send_does_not_reach_a_private_method
    errors = errors_in(<<~RUBY)
      SendTarget.new.public_send(:secret)
    RUBY

    assert_equal 1, errors.size
    errors[0].tap do |error|
      assert_instance_of Diagnostic::Ruby::UnresolvedSend, error
      assert_predicate error, :private_method?
      assert_equal :public_send, error.spelling
      assert_equal :secret, error.method
      assert_match(/`public_send` cannot call `secret` on `::SendTarget`, which declares it private/, error.header_line)
    end
  end

  def test_reports_a_name_that_resolves_nowhere
    errors = errors_in(<<~RUBY)
      SendTarget.new.send(:no_such_method_anywhere)
    RUBY

    assert_equal 1, errors.size
    errors[0].tap do |error|
      assert_instance_of Diagnostic::Ruby::UnresolvedSend, error
      refute_predicate error, :private_method?
      assert_equal :send, error.spelling
      assert_match(/`send` names `no_such_method_anywhere`, which type `::SendTarget` does not have/, error.header_line)
    end
  end

  # The diagnostic points at the literal, not at the `send` selector: the name is what has
  # to change.
  def test_points_at_the_name
    errors = errors_in(<<~RUBY)
      SendTarget.new.send(:no_such_method_anywhere)
    RUBY

    assert_equal ":no_such_method_anywhere", errors[0].location.source
  end

  # Arguments go through the ordinary dispatch path, so they are checked by the same
  # machinery every other call uses — nothing send-specific decides this.
  def test_checks_the_arguments_of_the_resolved_method
    errors = errors_in(<<~RUBY)
      SendTarget.new.send(:with_arg, 1)
    RUBY

    assert_equal 1, errors.size
    assert_instance_of Diagnostic::Ruby::ArgumentTypeMismatch, errors[0]
  end

  def test_checks_the_arity_of_the_resolved_method
    errors = errors_in(<<~RUBY)
      SendTarget.new.send(:title, "extra")
    RUBY

    assert_equal 1, errors.size
    assert_instance_of Diagnostic::Ruby::UnexpectedPositionalArgument, errors[0]
  end

  def test_checks_the_block_of_the_resolved_method
    errors = errors_in(<<~RUBY)
      SendTarget.new.send(:each_word) { |word| word.no_such_method_on_the_param }
    RUBY

    assert_equal 1, errors.size
    errors[0].tap do |error|
      assert_instance_of Diagnostic::Ruby::NoMethod, error
      assert_equal "::String", error.type.to_s
    end
  end

  # The limit case, and the reason this keys on the literal: the name is a value, so no
  # static analysis decides which method it is. A fix that types this one has guessed.
  def test_a_computed_name_stays_untyped
    assert_empty errors_in(<<~RUBY)
      name = :title
      SendTarget.new.send(name).no_such_method_on_the_result
    RUBY
  end

  # `:"a#{b}"` is a symbol node too, but not a literal one.
  def test_an_interpolated_name_stays_untyped
    assert_empty errors_in(<<~'RUBY')
      part = "tle"
      SendTarget.new.send(:"ti#{part}").no_such_method_on_the_result
    RUBY
  end

  # One dispatch, four spellings. `__send__` is the one a defensive library uses precisely
  # because `send` can be overridden, and a string names a method just as well as a symbol.
  def test_the_other_spellings_resolve_too
    ["__send__(:title)", "send(\"title\")", "__send__(\"title\")"].each do |spelling|
      errors = errors_in("SendTarget.new.#{spelling}.no_such_method_on_the_result\n")

      assert_equal 1, errors.size, "expected #{spelling} to resolve"
      assert_equal "::String", errors[0].type.to_s, "expected #{spelling} to resolve"
    end
  end

  # A `send` the receiver declares itself is an ordinary method that happens to share the
  # name. Reading its first argument as a method name would invent a call that is not there.
  def test_a_receivers_own_send_is_not_a_dispatch
    assert_empty errors_in(<<~RUBY)
      Bus.new.send(:notify, "payload")
    RUBY
  end

  # And it is still checked as the method it is.
  def test_a_receivers_own_send_is_checked_as_itself
    errors = errors_in(<<~RUBY)
      Bus.new.send(:notify)
    RUBY

    assert_equal 1, errors.size
    refute_instance_of Diagnostic::Ruby::UnresolvedSend, errors[0]
  end

  # An untyped receiver has no shape to ask, so there is no dispatch to read — and that is
  # what keeps this off code Steep knows nothing about, rather than a special case.
  def test_an_untyped_receiver_stays_untyped
    assert_empty errors_in(<<~RUBY)
      (_ = nil).send(:no_such_method_anywhere)
    RUBY
  end

  # The boundary from the issue, measured rather than asserted: a splat of unknown length
  # says nothing about how many arguments arrive. The `send` spelling reports exactly what
  # the direct spelling reports — Steep's own judgment about splats against a fixed arity,
  # unchanged. Resolving `send` adds no arity judgment of its own.
  def test_a_splat_says_what_the_direct_call_says
    direct = errors_in(<<~RUBY)
      def direct(*args)
        SendTarget.new.with_arg(*args)
      end
    RUBY

    sent = errors_in(<<~RUBY)
      def sent(*args)
        SendTarget.new.send(:with_arg, *args)
      end
    RUBY

    assert_equal direct.map(&:class), sent.map(&:class)
    assert_equal direct.map(&:header_line), sent.map(&:header_line)
  end

  # The severity templates are built from `ALL`, so the new class is picked up
  # automatically — that is what lets a project ramp it in the Steepfile.
  def test_the_diagnostic_is_configurable
    assert_includes Diagnostic::Ruby::ALL, Diagnostic::Ruby::UnresolvedSend
    assert_equal :error, Diagnostic::Ruby.default[Diagnostic::Ruby::UnresolvedSend]
    assert_equal :information, Diagnostic::Ruby.lenient[Diagnostic::Ruby::UnresolvedSend]
    assert_nil Diagnostic::Ruby.silent[Diagnostic::Ruby::UnresolvedSend]
  end
end
