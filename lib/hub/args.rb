# encoding: utf-8

require 'delegate'

module Hub
  # The Args class exists to make it more convenient to work with
  # command line arguments intended for git from within the Hub
  # codebase.
  #
  # The ARGV array is converted into an Args instance by the Hub
  # instance when instantiated.
  class Args < SimpleDelegator
    attr_accessor :executable

    attr_reader :noop, :skip
    alias_method :skip?, :skip
    alias_method :noop?, :noop

    def initialize(*args)
      super

      @executable = ENV['GIT'] || 'git'
      @skip = @noop = false
      @original_args = args.first
      @chain = [nil]
    end

    # Adds an `after` callback.
    # A callback can be a command or a proc.
    def after(cmd_or_args = nil, args = nil, &block)
      @chain << normalize_callback(cmd_or_args, args, block)
    end

    # Adds a `before` callback.
    # A callback can be a command or a proc.
    def before(cmd_or_args = nil, args = nil, &block)
      @chain.insert(
        @chain.index(nil), normalize_callback(cmd_or_args, args, block))
    end

    # Tells if there are multiple (chained) commands or not.
    def chained?
      @chain.any?
    end

    # Returns an array of all commands.
    def commands
      chain = @chain.dup
      chain[chain.index(nil)] = to_exec
      chain
    end

    # Skip running this command.
    def skip!
      @skip = true
    end

    # Mark that this command shouldn't really run.
    def noop!
      @noop = true
    end

    # Array of `executable` followed by all args suitable as arguments
    # for `exec` or `system` calls.
    def to_exec(args = self)
      Array(executable) + args
    end

    def add_exec_flags(flags)
      @executable = Array(executable) + (flags)
    end

    # All the words (as opposed to flags) contained in this argument
    # list.
    #
    # args = Args.new([ 'remote', 'add', '-f', 'tekkub' ])
    # args.words == [ 'remote', 'add', 'tekkub' ]
    def words
      reject { |arg| arg.index('-') == 0 }
    end

    # All the flags (as opposed to words) contained in this argument
    # list.
    #
    # args = Args.new([ 'remote', 'add', '-f', 'tekkub' ])
    # args.flags == [ '-f' ]
    def flags
      self - words
    end

    # Tests if arguments were modified since instantiation
    def changed?
      chained? || self != @original_args
    end

    def has_flag?(*flags)
      pattern = flags.flat_map { |f| Regexp.escape(f) }.join('|')

      !grep(/^#{pattern}(?:=|$)/).empty?
    end

    private

    def normalize_callback(cmd_or_args, args, block)
      case
      when block then block
      when args then [cmd_or_args] + args
      when cmd_or_args.kind_of?(Array) then to_exec(cmd_or_args)
      when cmd_or_args then cmd_or_args
      else fail ArgumentError, 'command or block required'
      end
    end
  end
end
