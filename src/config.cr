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

  # Applies external configuration sources (config file, env vars, CLI), in
  # precedence order. Doing nothing keeps every option at its registered default.
  def self.configure!(file : String? = nil, *, env : Bool = true, args : Bool = true) : Nil
    Superconf.configure!(file, env: env, args: args)
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
Crysterm.configure! unless ENV["CRYSTERM_NO_AUTO_CONFIGURE"]?
