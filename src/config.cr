require "superconf"

module Crysterm
  # Crysterm's configuration **is** the shared `Superconf` registry. Using the
  # shared singleton means options registered by libraries Crysterm builds on
  # (notably `tput`) appear in the same combined, configurable, dumpable list as
  # Crysterm's own options.
  #
  # `Crysterm::Config` is a transparent alias, so the familiar API keeps working:
  #
  # ```
  # Crysterm::Config.screen_resize_interval        # typed accessor
  # Crysterm::Config.get("tput.read_timeout", Time::Span)
  # Crysterm::Config.dump STDOUT, Crysterm::Config::Format::Pretty
  # ```
  alias Config = Superconf

  # Brand the shared config space for Crysterm apps: env vars are prefixed
  # `CRYSTERM_` and the default config file is `~/.config/crysterm/config.yml`.
  # (Env names are derived lazily, so this applies to options registered by
  # tput before this runs too.)
  Superconf.env_prefix = "CRYSTERM_"
  Superconf.app_name = "crysterm"

  # Opt in to external configuration sources (config file, env vars, CLI), in
  # precedence order. Thin wrapper over `Superconf.configure!`. Doing nothing
  # keeps every option at its registered default (the historical behavior).
  def self.configure!(file : String? = nil, *, env : Bool = true, args : Bool = true) : Nil
    Superconf.configure!(file, env: env, args: args)
  end
end

require "./config/builtins"
