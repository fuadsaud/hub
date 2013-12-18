module Hub
  module Context
    class GitHubURL < URI::HTTPS
      extend Forwardable

      attr_reader :project

      def_delegator :project, :name, :project_name
      def_delegator :project, :owner, :project_owner

      def self.resolve(url, local_repo)
        u = URI(url)

        if %w(http https).include?(u.scheme) &&
          (project = GitHubProject.from_url(u, local_repo))
          new(u.scheme, u.userinfo, u.host, u.port, u.registry,
              u.path, u.opaque, u.query, u.fragment, project)
        end
      rescue URI::InvalidURIError
        nil
      end

      def initialize(*args)
        @project = args.pop

        super(*args)
      end

      # segment of path after the project owner and name
      def project_path
        path.split('/', 4)[3]
      end
    end
  end
end
