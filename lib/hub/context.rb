require 'shellwords'
require 'forwardable'
require 'uri'

require_relative 'context/git_reader'
require_relative 'context/git_reader_methods'
require_relative 'context/system'

module Hub
  # Methods for inspecting the environment, such as reading git config,
  # repository info, and other.
  module Context
    extend Forwardable

    NULL = defined?(File::NULL) ? File::NULL : File.exist?('/dev/null') ? '/dev/null' : 'NUL'

    Error = Class.new(RuntimeError)
    FatalError = Class.new(Error)
    private

    def git_reader
      @git_reader ||= GitReader.new ENV['GIT']
    end

    include GitReaderMethods
    private :git_config, :git_command

    def local_repo(fatal = true)
      @local_repo ||= begin
        if is_repo?
          LocalRepo.new git_reader, current_dir
        elsif fatal
          raise FatalError, "Not a git repository"
        end
      end
    end

    repo_methods = [
      :current_branch,
      :current_project, :upstream_project,
      :repo_owner, :repo_host,
      :remotes, :remotes_group, :origin_remote
    ]
    def_delegator :local_repo, :name, :repo_name
    def_delegators :local_repo, *repo_methods
    private :repo_name, *repo_methods

    def master_branch
      if local_repo(false)
        local_repo.master_branch
      else
        # FIXME: duplicates functionality of LocalRepo#master_branch
        Branch.new nil, 'refs/heads/master'
      end
    end

    class LocalRepo < Struct.new(:git_reader, :dir)
      include GitReaderMethods

      def name
        if project = main_project
          project.name
        else
          File.basename(dir)
        end
      end

      def repo_owner
        if project = main_project
          project.owner
        end
      end

      def repo_host
        project = main_project and project.host
      end

      def main_project
        remote = origin_remote and remote.project
      end

      def upstream_project
        if branch = current_branch and upstream = branch.upstream and upstream.remote?
          remote = remote_by_name upstream.remote_name
          remote.project
        end
      end

      def current_project
        upstream_project || main_project
      end

      def current_branch
        if branch = git_command('symbolic-ref -q HEAD')
          Branch.new self, branch
        end
      end

      def master_branch
        if remote = origin_remote
          default_branch = git_command("rev-parse --symbolic-full-name #{remote}")
        end
        Branch.new(self, default_branch || 'refs/heads/master')
      end

      def remotes
        @remotes ||= begin
          # TODO: is there a plumbing command to get a list of remotes?
          list = git_command('remote').to_s.split("\n")
          # force "origin" to be first in the list
          main = list.delete('origin') and list.unshift(main)
          list.map { |name| Remote.new self, name }
        end
      end

      def remotes_group(name)
        git_config "remotes.#{name}"
      end

      def origin_remote
        remotes.first
      end

      def remote_by_name(remote_name)
        remotes.find {|r| r.name == remote_name }
      end

      def known_hosts
        hosts = git_config('hub.host', :all).to_s.split("\n")
        hosts << default_host
        # support ssh.github.com
        # https://help.github.com/articles/using-ssh-over-the-https-port
        hosts << "ssh.#{default_host}"
      end

      def self.default_host
        ENV['GITHUB_HOST'] || main_host
      end

      def self.main_host
        'github.com'
      end

      extend Forwardable
      def_delegators :'self.class', :default_host, :main_host

      def ssh_config
        @ssh_config ||= SshConfig.new
      end
    end

    class GithubProject < Struct.new(:local_repo, :owner, :name, :host)
      def self.from_url(url, local_repo)
        if local_repo.known_hosts.include? url.host
          _, owner, name = url.path.split('/', 4)
          GithubProject.new(local_repo, owner, name.sub(/\.git$/, ''), url.host)
        end
      end

      attr_accessor :repo_data

      def initialize(*args)
        super
        self.name = self.name.tr(' ', '-')
        self.host ||= (local_repo || LocalRepo).default_host
        self.host = host.sub(/^ssh\./i, '') if 'ssh.github.com' == host.downcase
      end

      def private?
        repo_data ? repo_data.fetch('private') :
          host != (local_repo || LocalRepo).main_host
      end

      def owned_by(new_owner)
        new_project = dup
        new_project.owner = new_owner
        new_project
      end

      def name_with_owner
        "#{owner}/#{name}"
      end

      def ==(other)
        name_with_owner == other.name_with_owner
      end

      def remote
        local_repo.remotes.find { |r| r.project == self }
      end

      def web_url(path = nil)
        project_name = name_with_owner
        if project_name.sub!(/\.wiki$/, '')
          unless '/wiki' == path
            path = if path =~ %r{^/commits/} then '/_history'
                   else path.to_s.sub(/\w+/, '_\0')
                   end
            path = '/wiki' + path
          end
        end
        "https://#{host}/" + project_name + path.to_s
      end

      def git_url(options = {})
        if options[:https] then "https://#{host}/"
        elsif options[:private] or private? then "git@#{host}:"
        else "git://#{host}/"
        end + name_with_owner + '.git'
      end
    end

    class GithubURL < URI::HTTPS
      extend Forwardable

      attr_reader :project
      def_delegator :project, :name, :project_name
      def_delegator :project, :owner, :project_owner

      def self.resolve(url, local_repo)
        u = URI(url)
        if %[http https].include? u.scheme and project = GithubProject.from_url(u, local_repo)
          self.new(u.scheme, u.userinfo, u.host, u.port, u.registry,
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

    class Branch < Struct.new(:local_repo, :name)
      alias to_s name

      def short_name
        name.sub(%r{^refs/(remotes/)?.+?/}, '')
      end

      def master?
        master_name = if local_repo then local_repo.master_branch.short_name
        else 'master'
        end
        short_name == master_name
      end

      def upstream
        if branch = local_repo.git_command("rev-parse --symbolic-full-name #{short_name}@{upstream}")
          Branch.new local_repo, branch
        end
      end

      def remote?
        name.index('refs/remotes/') == 0
      end

      def remote_name
        name =~ %r{^refs/remotes/([^/]+)} and $1 or
          raise Error, "can't get remote name from #{name.inspect}"
      end
    end

    class Remote < Struct.new(:local_repo, :name)
      alias to_s name

      def ==(other)
        other.respond_to?(:to_str) ? name == other.to_str : super
      end

      def project
        urls.each_value { |url|
          if valid = GithubProject.from_url(url, local_repo)
            return valid
          end
        }
        nil
      end

      def urls
        return @urls if defined? @urls
        @urls = {}
        local_repo.git_command('remote -v').to_s.split("\n").map do |line|
          next if line !~ /^(.+?)\t(.+) \((.+)\)$/
          remote, uri, type = $1, $2, $3
          next if remote != self.name
          if uri =~ %r{^[\w-]+://} or uri =~ %r{^([^/]+?):}
            uri = "ssh://#{$1}/#{$'}" if $1
            begin
              @urls[type] = uri_parse(uri)
            rescue URI::InvalidURIError
            end
          end
        end
        @urls
      end

      def uri_parse uri
        uri = URI.parse uri
        uri.host = local_repo.ssh_config.get_value(uri.host, 'hostname') { uri.host }
        uri.user = local_repo.ssh_config.get_value(uri.host, 'user') { uri.user }
        uri
      end
    end

    ## helper methods for local repo, GH projects

    def github_project(name, owner = nil)
      if owner and owner.index('/')
        owner, name = owner.split('/', 2)
      elsif name and name.index('/')
        owner, name = name.split('/', 2)
      else
        name ||= repo_name
        owner ||= github_user
      end

      if local_repo(false) and main_project = local_repo.main_project
        project = main_project.dup
        project.owner = owner
        project.name = name
        project
      else
        GithubProject.new(local_repo(false), owner, name)
      end
    end

    def git_url(owner = nil, name = nil, options = {})
      project = github_project(name, owner)
      project.git_url({:https => https_protocol?}.update(options))
    end

    def resolve_github_url(url)
      GithubURL.resolve(url, local_repo) if url =~ /^https?:/
    end

    # legacy setting
    def http_clone?
      git_config('--bool hub.http-clone') == 'true'
    end

    def https_protocol?
      git_config('hub.protocol') == 'https' or http_clone?
    end

    def git_alias_for(name)
      git_config "alias.#{name}"
    end

    def rev_list(a, b)
      git_command("rev-list --cherry-pick --right-only --no-merges #{a}...#{b}")
    end

    PWD = Dir.pwd

    def current_dir
      PWD
    end

    def git_dir
      git_command 'rev-parse -q --git-dir'
    end

    def is_repo?
      !!git_dir
    end

    def git_editor
      # possible: ~/bin/vi, $SOME_ENVIRONMENT_VARIABLE, "C:\Program Files\Vim\gvim.exe" --nofork
      editor = git_command 'var GIT_EDITOR'
      editor = ENV[$1] if editor =~ /^\$(\w+)$/
      editor = File.expand_path editor if (editor =~ /^[~.]/ or editor.index('/')) and editor !~ /["']/
      # avoid shellsplitting "C:\Program Files"
      if File.exist? editor then [editor]
      else editor.shellsplit
      end
    end

    include System
    extend System
  end
end
