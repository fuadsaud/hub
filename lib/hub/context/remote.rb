module Hub
  module Context
    class Remote < Struct.new(:local_repo, :name)
      alias_method :to_s, :name

      def ==(other)
        other.respond_to?(:to_str) ? name == other.to_str : super
      end

      def project
        urls.each_value do |url|
          if valid = GitHubProject.from_url(url, local_repo)
            return valid
          end
        end

        nil
      end

      def urls
        return @urls if defined? @urls

        @urls = {}

        local_repo.git_command('remote -v').to_s.split("\n").map do |line|
          next if line !~ /^(?<remote>.+?)\t(?<uri>.+) \((?<type>.+)\)$/

          remote, uri, type =
            Regexp.last_match(:remote),
            Regexp.last_match(:uri),
            Regexp.last_match(:type)

          next if remote != self.name

          if uri =~ %r(^[\w-]+://) || uri =~ %r(^([^/]+?):)
            uri = "ssh://#{$1}/#{$'}" if $1
            begin
              @urls[type] = uri_parse(uri)
            rescue URI::InvalidURIError
            end
          end
        end

        @urls
      end

      def uri_parse(uri)
        uri = URI.parse uri

        uri.host =
          local_repo.ssh_config.get_value(uri.host, 'hostname') { uri.host }
        uri.user =
          local_repo.ssh_config.get_value(uri.host, 'user') { uri.user }

        uri
      end
    end
  end
end
