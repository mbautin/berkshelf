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

    # Resolve variable substitutions, such as ${name} and ${version}.
    def substitute_variables(value)
      if value
        # Substitute name
        value = value.gsub('${name}', @name)

        # # Substitute version obtained from the metadata file.
        # if @version_from_metadata
        #   version = @version_from_metadata.strip.gsub(/^(=|~>)/, '').strip
        #   if version !~ /[<=>~]/
        #     # We have what looks like a well-specified version
        #     value = value.gsub('${version}', version)
        #   end
        # end
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
      @version_from_metadata = options[:version_from_metadata]

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
        return local_revision(destination)
      end

      clone_dir = clone

      effective_branch = ref || branch
      if effective_branch && effective_branch.include?('${version}')
        tags = Berkshelf::Git.tags(clone_dir)
        version_constraint = Solve::Constraint.new(@version_from_metadata)
        branch_regex = Regexp.new(effective_branch.sub('${version}', '([0-9]+\.[0-9]+\.[0-9]+)'))
        matching_tags = tags.map do |tag|
          if tag =~ branch_regex
            version = Solve::Version.new($1)
            # puts "version=#{version}, constraint=#{version_constraint}"
            # puts "version.class=#{version.class}, constraint.class=#{version_constraint.class}"
            # begin
            #   version_constraint.satisfies?(version)
            # rescue => exception
            #   puts exception
            #   puts exception.backtrace
            # end
            if version_constraint.satisfies?(version)
              OpenStruct.new(:tag => tag, :version => version)
            end
          end
        end.delete_if {|result| result.nil? }

        puts "DEBUG: matching_tags=#{matching_tags}"
        unless matching_tags.empty?
          effective_branch = matching_tags.max_by {|t| t.version }.tag
          puts "DEBUG: Using branch #{effective_branch}"
        end
      end

      Berkshelf::Git.checkout(clone_dir, effective_branch) if effective_branch
      @ref = Berkshelf::Git.rev_parse(clone)

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
