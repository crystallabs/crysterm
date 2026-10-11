require "superconf"

module Crysterm
  # Crysterm's configuration **is** the shared `Superconf` registry, so options
  # registered by the libraries Crysterm builds on (notably `tput`) appear in the
  # same combined, configurable, dumpable list as Crysterm's own.
  #
  # `Crysterm::Config` is a transparent alias:
  #
  # ```
  # Crysterm::Config.window_resize_interval # typed accessor
  # Crysterm::Config.get("tput.read_timeout", Time::Span)
  # Crysterm::Config.dump STDOUT, Crysterm::Config::Format::Pretty
  # ```
  alias Config = Superconf

  # Env vars are prefixed `CRYSTERM_` and the default config file is
  # `~/.config/crysterm/config.yml`. Env names are derived lazily, so this also
  # applies to options tput registered before this runs.
  Superconf.env_prefix = "CRYSTERM_"
  Superconf.app_name = "crysterm"

  # The CLI flag that loads an extra config file. Namespaced: an application's
  # own parser is free to own the generic `--config`.
  CONFIG_FLAG = "--crysterm-config"

  # The CLI flag that dumps the resolved configuration and exits, in an optional
  # format (`yaml|json|env|pretty|report`). Namespaced like `CONFIG_FLAG`.
  DUMP_CONFIG_FLAG = "--crysterm-dump-config"

  # Applies external configuration sources (config file, env vars, CLI), in
  # precedence order. Doing nothing keeps every option at its registered default.
  #
  # `ARGV` is read but never modified — the application's own option parser sees
  # exactly the arguments the user typed, including any Crysterm consumed. And
  # the two file/dump built-ins are only recognized under their namespaced
  # spellings, `CONFIG_FLAG` and `DUMP_CONFIG_FLAG`: a bare `--config` /
  # `--dump-config` in `ARGV` belongs to the application and is passed over.
  def self.configure!(file : String? = nil, *, env : Bool = true, args : Bool = true, argv : Array(String) = ARGV) : Nil
    Superconf.configure! file, env: env, args: false
    Superconf.load_args namespaced_argv(argv), consume: false if args
  end

  # A copy of *argv* speaking Superconf's built-in flag names: the namespaced
  # spellings are translated to the generic ones Superconf registers, and any
  # genuinely generic `--config`/`--dump-config` is dropped so Superconf does not
  # claim the application's own flag. Every other argument is passed through
  # untouched (registered options keep their own derived flags).
  private def self.namespaced_argv(argv : Array(String)) : Array(String)
    argv.compact_map do |arg|
      name = arg.split('=', 2).first
      if name == CONFIG_FLAG || name == DUMP_CONFIG_FLAG
        arg.sub "--crysterm-", "--"
      elsif name == "--config" || name == "--dump-config"
        nil
      else
        arg
      end
    end
  end

  # No flags of the application's own (the `except:` default below).
  EMPTY_FLAGS = [] of String

  # *argv* without the toolkit's options: what the application's own option
  # parser should see, the way `QApplication` leaves `argv` to the
  # application after taking its `-style`, `-platform` and the like.
  # Crysterm reads its options from `ARGV` at load time without consuming
  # them (`.configure!`), so a parser given `ARGV` as typed would report them
  # as unknown, or take a separate-word value (`--colors-theme dark`) for a
  # file name.
  #
  # Dropped: every registered option's flag — with its `=value` or
  # separate-word value for a valued option, and its `--no-` negation for a
  # boolean — plus `CONFIG_FLAG` and `DUMP_CONFIG_FLAG`. Everything from `--`
  # on is the application's. *except* names flags the application owns,
  # kept even where a toolkit option derives the same spelling (the
  # application's flag wins, as in `.toolkit_options_help`). *argv* itself
  # is left as it is.
  #
  # ```
  # parser.parse Crysterm.strip_toolkit_args(ARGV, except: {"-v", "--verbose"})
  # ```
  def self.strip_toolkit_args(argv : Array(String) = ARGV, *, except : Enumerable(String) = EMPTY_FLAGS) : Array(String)
    keep = except.to_set
    flags, valued = toolkit_flags(keep)
    valued << CONFIG_FLAG unless keep.includes?(CONFIG_FLAG)
    dump = !keep.includes?(DUMP_CONFIG_FLAG)

    out = [] of String
    i = 0
    while i < argv.size
      arg = argv[i]
      if arg == "--"
        out.concat argv[i..]
        break
      end
      name, eq, _ = arg.partition('=')
      i += 1
      if eq.empty? && flags.includes?(arg)
        # a boolean, or its negation
      elsif valued.includes?(name)
        # `--flag=value`, or `--flag value` — the next word whatever it is,
        # as `OptionParser` takes a required value
        i += 1 if eq.empty?
      elsif dump && name == DUMP_CONFIG_FLAG
        # the format is optional: the next word unless it is a flag of the
        # toolkit's own, as `OptionParser` takes an optional value
        if eq.empty? && (nxt = argv[i]?) && !flags.includes?(nxt) && !valued.includes?(nxt) && nxt != DUMP_CONFIG_FLAG
          i += 1
        end
      else
        out << arg
      end
    end
    out
  end

  # The toolkit's flags, less *keep*: `{booleans with their negations,
  # valued}`. A negation is derived as Superconf derives it — `--no-` for a
  # long flag — and left out where it would be another option's own flag
  # (`color` next to `no_color`), as Superconf leaves it out.
  private def self.toolkit_flags(keep : Set(String)) : {Set(String), Set(String)}
    primaries = Set(String).new
    Config.each { |opt| primaries << opt.cli }
    flags = Set(String).new
    valued = Set(String).new
    Config.each do |opt|
      next if keep.includes?(opt.cli)
      if opt.bool?
        flags << opt.cli
        if no = toolkit_negation(opt, primaries)
          flags << no
        end
      else
        valued << opt.cli
      end
    end
    {flags, valued}
  end

  # The `--no-` negation of the boolean *opt*, or `nil` where Superconf
  # registers none: a short flag, or a spelling another option owns.
  private def self.toolkit_negation(opt : Superconf::AbstractOption, primaries : Set(String)) : String?
    no = opt.cli.sub("--", "--no-")
    no != opt.cli && !primaries.includes?(no) ? no : nil
  end

  # The toolkit's options formatted as `OptionParser` prints an application's
  # own help: every registered option (Crysterm's and its libraries') with
  # its description and default, the booleans' `--no-` negations, and the
  # file and dump flags, under a banner naming the config file and the
  # environment variables. For an application to print under its own help
  # (or behind a verbose switch, as the options are many). *except* as in
  # `.strip_toolkit_args`.
  def self.toolkit_options_help(*, except : Enumerable(String) = EMPTY_FLAGS) : String
    keep = except.to_set
    config_path = Config.default_config_path.sub(Path.home.to_s, "~")
    parser = OptionParser.new
    parser.banner = <<-BANNER
      Crysterm toolkit options. Each can also be set in #{config_path}
      or by a #{Superconf.env_prefix}* environment variable; see #{DUMP_CONFIG_FLAG}.
      BANNER
    primaries = Set(String).new
    Config.each { |opt| primaries << opt.cli }
    Config.each do |opt|
      next if keep.includes?(opt.cli)
      default = opt.default_string.presence || "\"\""
      description = wrap_help("#{opt.description} (default: #{default})")
      if opt.bool?
        parser.on(opt.cli, description) { }
        if no = toolkit_negation(opt, primaries)
          parser.on(no, "Disable #{opt.key}") { }
        end
      else
        parser.on("#{opt.cli}=VALUE", description) { |_| }
      end
    end
    parser.on("#{CONFIG_FLAG}=FILE", wrap_help("Load Crysterm configuration from FILE (YAML or JSON)")) { |_| } unless keep.includes?(CONFIG_FLAG)
    parser.on("#{DUMP_CONFIG_FLAG} [FORMAT]",
      wrap_help("Dump the Crysterm configuration (yaml|json|env|pretty|report) and exit")) { |_| } unless keep.includes?(DUMP_CONFIG_FLAG)
    parser.to_s
  end

  # Word-wraps *text* to fit next to `OptionParser`'s flag column within 80
  # columns.
  private def self.wrap_help(text : String, width : Int32 = 42) : String
    lines = [] of String
    line = ""
    text.split(' ') do |word|
      if line.empty?
        line = word
      elsif line.size + 1 + word.size <= width
        line += " #{word}"
      else
        lines << line
        line = word
      end
    end
    lines << line unless line.empty?
    lines.join('\n')
  end
end

require "./config/builtins"

# Apply external configuration at load time, so every app honors the config file,
# `CRYSTERM_*` env vars and CLI flags with no per-app `configure!` call. Must run
# before any `Window` is constructed: many options are read as `Window` property
# defaults at the start of `initialize`, too early for a later call to affect.
#
# Opt out via `CRYSTERM_NO_AUTO_CONFIGURE`. Apps may still call
# `Crysterm.configure!` again themselves; it re-applies in precedence order.
Crysterm.configure! unless ENV["CRYSTERM_NO_AUTO_CONFIGURE"]?.presence
