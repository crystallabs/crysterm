require "../src/crysterm"

# Dumps Crysterm's global configuration — every registered option together with
# its current value and the *source* that value came from (default, config
# file, environment variable, command-line flag, or a runtime assignment).
#
# This is the configuration analog of `tput`'s `examples/dump.cr`: where that
# one reports *detected* terminal facts, this one reports *configurable*
# settings, in a format that is itself a valid config file.
#
# Usage:
#   crystal run examples/config-dump.cr                       # YAML (re-loadable)
#   crystal run examples/config-dump.cr -- --dump-config=json    # JSON config
#   crystal run examples/config-dump.cr -- --dump-config=pretty  # table + source
#   crystal run examples/config-dump.cr -- --dump-config=report  # rich JSON
#
# Try overriding a value and watch the `source` column change:
#   CRYSTERM_SCREEN_RESIZE_INTERVAL=0.5 crystal run examples/config-dump.cr -- \
#     --render-optimization=smart_csr,bce --dump-config=pretty

# Example of an app appending its own option via the `option` macro. It
# instantly gains an env var (CRYSTERM_MYAPP_REFRESH), a CLI flag
# (--myapp-refresh), a config key (myapp.refresh), a line in every dump, and a
# typed accessor `Crysterm::Config.myapp_refresh : Time::Span`.
#
# `Crysterm::Config` is an alias of the shared `Superconf` registry; declare
# options by reopening `Superconf` (you can't reopen an alias).
module Superconf
  option "myapp.refresh", 1.second,
    description: "Example app-defined option: data refresh interval"
end

# Opt in to env + CLI overrides. `--dump-config[=FORMAT]` is handled here and
# exits; otherwise we fall through and print the pretty table ourselves.
#
# This dumps *configuration* only. Terminal *detections* (probed emulator and
# feature facts) are tput's concern, not configuration — see tput's own
# `examples/dump.cr` or `screen.tput.dump` for those.
Crysterm.configure!

puts "Crysterm configuration (source shows where each value came from):"
puts "(example: Config.myapp_refresh = #{Crysterm::Config.myapp_refresh})"
puts
Crysterm::Config.dump STDOUT, Crysterm::Config::Format::Pretty
