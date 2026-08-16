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
