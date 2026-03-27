require 'puppet_forge'
require 'puppet_metadata'

module MetadataJsonDeps
  class ForgeVersions
    def initialize(cache = {})
      @cache = cache
    end

    def get_module(name)
      name = PuppetForge::V3.normalize_name(name)
      begin
        @cache[name] ||= PuppetForge::Module.find(name)
      rescue Faraday::ResourceNotFound
        raise PuppetForge::ModuleNotFound.new("Dependency #{name} not found on forge.puppet.com")
      end
    end
  end

  def self.build_fixtures(filename)
    require 'yaml'

    result = {}

    dependencies = PuppetMetadata.read(filename).dependencies
    if dependencies.any?
      forge = ForgeVersions.new

      repositories = {}
      result['fixtures'] = {'repositories' => repositories}

      dependencies.each do |dependency, _constraint|
        mod = forge.get_module(dependency)
        # TODO: The forge should expose the source URL directly
        repositories[mod.name] = mod.current_release.metadata[:source]
      end
    end

    puts result.to_yaml
  end

  # Bump a dependency in a filename
  #
  # @param [String] filename A path to a metadata file. An error is raised if
  #   it's invalid metadata.
  # @param [String] module_name The module name listed in dependencies. It must
  #   be normalized to the forge style (using a dash). It can fall back to a
  #   slash if metadata uses a slash.
  # @param [String] upper_bound The new upper bound for the module name
  # @return [Array<String>] An array with the old and new version. Can be used
  #   to determine if a change was made.
  # @see PuppetMetadata.read
  def self.bump_dependency(filename, module_name, upper_bound)
    metadata = PuppetMetadata.read(filename)

    requirement = metadata.dependencies[module_name]
    unless requirement
      # TODO: normalize keys in puppet_metadata so we don't need 2 lookups?
      module_name = module_name.tr('-', '/')
      requirement = metadata.dependencies[module_name]
      raise Exception.new("Dependency #{module_name} not found") unless requirement
    end

    return [requirement.to_s, requirement.to_s] if requirement.end == upper_bound

    new = ">= #{requirement.begin} < #{upper_bound}"

    new_metadata = metadata.metadata.clone
    new_metadata['dependencies'].each do |dependency|
      if dependency['name'] == module_name
        dependency['version_requirement'] = new
      end
    end

    File.write(filename, JSON.pretty_generate(new_metadata) + "\n")

    [requirement.to_s, new]
  end

  # @summary Check dependencies for all given metadata files
  # @param [Array[String]] filenames
  #   The filenames to run on
  # @return [Array<Hash>] one entry per file, each with :filename, :exit_code,
  #   and :dependencies (Array of dependency result Hashes). Each dependency
  #   Hash has :name, :constraint, :status (:ok, :outdated, :deprecated), and
  #   optionally :current_release, :superseded_by, or :deprecated_for.
  def self.check(filenames)
    forge = ForgeVersions.new

    filenames.map do |filename|
      metadata = PuppetMetadata.read(filename)
      file_exit_code = 0
      dependencies = []

      metadata.dependencies.each do |dependency, constraint|
        mod = forge.get_module(dependency)

        if mod.deprecated_at
          file_exit_code |= 2
          dep = {name: dependency, constraint: constraint, status: :deprecated}
          dep[:superseded_by] = mod.superseded_by[:slug] if mod.superseded_by
          dep[:deprecated_for] = mod.deprecated_for if mod.deprecated_for
          dependencies << dep
        else
          current = mod.current_release.version

          if metadata.satisfies_dependency?(dependency, current)
            dependencies << {name: dependency, constraint: constraint, status: :ok, current_release: current}
          else
            file_exit_code |= 1
            dependencies << {name: dependency, constraint: constraint, status: :outdated, current_release: current}
          end
        end
      end

      {filename: filename, exit_code: file_exit_code, dependencies: dependencies}
    end
  rescue Interrupt
    []
  end

  # @summary Run the application, printing text output
  # @param [Array[String]] filenames
  #   The filenames to run on
  # @param [Boolean] verbose
  #   Whether or not to run in verbose mode
  # @return [Integer] the exit code
  def self.run(filenames, verbose = false)
    exit_code = 0

    check(filenames).each do |file|
      puts "Checking #{file[:filename]}"
      exit_code |= file[:exit_code]

      file[:dependencies].each do |dep|
        case dep[:status]
        when :deprecated
          if dep[:superseded_by]
            puts "  #{dep[:name]} was superseded by #{dep[:superseded_by]}"
          elsif dep[:deprecated_for]
            puts "  #{dep[:name]} was deprecated: #{dep[:deprecated_for]}"
          else
            puts "  #{dep[:name]} was deprecated"
          end
        when :outdated
          puts "  #{dep[:name]} (#{dep[:constraint]}) doesn't match #{dep[:current_release]}"
        when :ok
          puts "  #{dep[:name]} (#{dep[:constraint]}) matches #{dep[:current_release]}" if verbose
        end
      end
    end

    exit_code
  end
end
