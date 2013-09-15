require 'ostruct'

module Berkshelf
  class GitLocation
    class << self
      # Create a temporary directory for the cloned repository within Berkshelf's
      # temporary directory
      #
      # @return [String]
      #   the path to the created temporary directory
      def tmpdir
        @tmpdir ||= Berkshelf.mktmpdir
      end
    end

    include Location

    set_location_key :git
    set_valid_options :ref, :branch, :tag, :rel

    attr_accessor :uri
    attr_accessor :branch
    attr_accessor :rel
    attr_accessor :ref
    attr_reader :options

    alias_method :tag, :branch

    # Resolve some of the variable substitutions, e.g. ${name}. ${version} cannot be resolved
    # here because it is not known until available tags are retrieved.
    def substitute_variables(value)
      if value
        # Substitute name
        value = value.gsub('${name}', @name)
      end

      value
    end

    # @param [#to_s] name
    # @param [Solve::Constraint] version_constraint
    # @param [Hash] options
    #
    # @option options [String] :git
    #   the Git URL to clone
    # @option options [String] :ref
    #   the commit hash or an alias to a commit hash to clone
    # @option options [String] :branch
    #   same as ref
    # @option options [String] :tag
    #   same as tag
    # @option options [String] :rel
    #   the path within the repository to find the cookbook
    def initialize(name, version_constraint, options = {})
      @name               = name
      @version_constraint = version_constraint
      @uri                = options[:git]
      @branch             = options[:branch] || options[:tag] || 'master'
      @ref                = options[:ref]
      @rel                = options[:rel]

      @branch = substitute_variables(@branch)
      @ref = substitute_variables(@ref)
      @rel = substitute_variables(@rel)

      Git.validate_uri!(@uri)
    end

    # @param [#to_s] destination
    #
    # @return [Berkshelf::CachedCookbook]
    def download(destination)
      if cached?(destination)
        @ref ||= Berkshelf::Git.rev_parse(revision_path(destination))
        @branch = nil if @branch == 'master'  # master may be misleading, and we show the ref anyway
        return local_revision(destination)
      end

      clone_dir = clone

      effective_branch = ref || branch
      if effective_branch && effective_branch.include?('${version}')
        tags = Berkshelf::Git.tags(clone_dir)

        branch_regex = Regexp.new(effective_branch.sub('${version}', '([0-9]+\.[0-9]+\.[0-9]+)'))
        matching_tags = tags.map do |tag|
          if tag =~ branch_regex
            version = Solve::Version.new($1)
            if version_constraint.satisfies?(version)
              OpenStruct.new(:tag => tag, :version => version)
            end
          end
        end.delete_if {|result| result.nil? }

        if matching_tags.empty?
          Berkshelf.logger.warn(
            "No tags of the form #{effective_branch} with the version matching constraint " +
            "#{version_constraint} found for #{@name}"
          )
        else
          latest_version_and_tag = matching_tags.max_by {|t| t.version }
          @version_constraint = Solve::Constraint.new(latest_version_and_tag.version.to_s)
          effective_branch = latest_version_and_tag.tag
          Berkshelf.logger.debug(
            "Versions of #{@name} matching constraint #{version_constraint}: " +
            matching_tags.map {|t| t.version }.sort.map(&:to_s).join(', ') +
            "; using tag: #{effective_branch}"
          )

          # Modify @ref or @branch to remove substitution variables from the output.
          if ref
            @ref = effective_branch
            @branch = nil
          else
            @branch = effective_branch
            @ref = nil
          end
        end
      end

      Berkshelf::Git.checkout(clone_dir, effective_branch) if effective_branch
      @ref = Berkshelf::Git.rev_parse(clone)
      if branch != effective_branch
        # Don't show branch name that does not correspond to what we have checked out.
        @branch = nil
      end

      tmp_path = rel ? File.join(clone, rel) : clone
      unless File.chef_cookbook?(tmp_path)
        msg = "Cookbook '#{name}' not found at git: #{uri}"
        msg << " with branch '#{branch}'" if branch
        msg << " with ref '#{ref}'" if ref
        msg << " at path '#{rel}'" if rel
        raise CookbookNotFound, msg
      end

      cb_path = File.join(destination, "#{name}-#{ref}")
      FileUtils.rm_rf(cb_path)
      FileUtils.mv(tmp_path, cb_path)

      cached = CachedCookbook.from_store_path(cb_path)
      validate_cached(cached)

      cached
    end

    def to_hash
      super.tap do |h|
        h[:value]  = self.uri
        h[:branch] = self.branch if branch
      end
    end

    def to_s
      s = "#{self.class.location_key}: '#{uri}'"
      s << " with branch: '#{branch}'" if branch
      s << " at ref: '#{ref}'" if ref
      s
    end

    private

      def git
        @git ||= Berkshelf::Git.new(uri)
      end

      def clone
        tmp_clone = File.join(self.class.tmpdir, uri.gsub(/[\/:]/,'-'))

        unless File.exists?(tmp_clone)
          Berkshelf::Git.clone(uri, tmp_clone)
        end

        tmp_clone
      end

      def cached?(destination)
        revision_path(destination) && File.exists?(revision_path(destination))
      end

      def local_revision(destination)
        path = revision_path(destination)
        cached = Berkshelf::CachedCookbook.from_store_path(path)
        validate_cached(cached)
        return cached
      end

      def revision_path(destination)
        return unless ref
        File.join(destination, "#{name}-#{ref}")
      end
  end
end
