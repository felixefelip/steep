# A project written to a temporary directory, for the specializations
# runner to record and an ordinary check to read back.
module SpecializationsProjectHelper
  STEEPFILE = <<~STEEPFILE
    target :app do
      signature "sig"
      check "app"
    end
  STEEPFILE

  def dirs
    @dirs ||= []
  end

  def write(relative, content)
    path = current_dir + relative
    path.parent.mkpath
    path.write(content)
    path
  end

  def setup_project(steepfile: STEEPFILE)
    write("Steepfile", steepfile)
    project = Steep::Project.new(steepfile_path: current_dir + "Steepfile")
    Steep::Project::DSL.parse(project, steepfile, filename: (current_dir + "Steepfile").to_s)
    project
  end

  # `{ "method name" => type }` for every `def` in `path`, as an ordinary check
  # of the project sees them.
  def body_types(project, path)
    typing = checked(project, path)
    result = {}
    typing.each_typing do |node, _|
      next unless node.type == :def

      body = node.children[2] or next
      result[node.children[0].to_s] = typing.type_of(node: body).to_s
    end
    result
  end

  # An ordinary check of `path` in `project`.
  def checked(project, path)
    target = project.targets.first or raise
    loader = Steep::Project::Target.construct_env_loader(options: target.options, project: project)
    file_loader = Steep::Services::FileLoader.new(base_dir: project.base_dir)
    file_loader.each_path_in_patterns(target.signature_pattern) do |sig|
      absolute = project.absolute_path(sig)
      loader.add(path: absolute) if absolute.file?
    end

    status = Steep::Services::SignatureService.load_from(loader, implicitly_returns_nil: target.implicitly_returns_nil, underscore_casts: target.underscore_casts).status
    source = Steep::Source.parse(path.read, path: path, factory: status.subtyping.factory)
    Steep::Services::TypeCheckService.type_check(
      source: source,
      subtyping: status.subtyping,
      constant_resolver: status.constant_resolver,
      cursor: nil,
      contracts: project.contracts,
      postconditions: project.postconditions,
      callbacks: project.callbacks,
      specializations: project.specializations,
      literal_method_registry: project.literal_method_registry,
      delegation_registry: project.delegation_registry,
      constructor_bindings: project.constructor_binding_registry,
      return_forwarding: project.return_forwarding_registry,
      return_alias: project.return_alias_registry
    )
  end
end
