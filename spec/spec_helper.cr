require "spec"
require "../src/crysterm"
require "../src/misc/util/helpers"

# Specs must NEVER touch the real terminal, however they are run.
#
# `screen.headless` defaults to `Auto`, which resolves from `STDOUT.tty?`. Under
# CI (output redirected) that is already headless, so IO-less `Window.new` calls
# quietly bind `IO::Memory`. Run the same suite interactively (`crystal spec` in
# a terminal) and the identical code binds the real `STDIN`/`STDOUT` instead:
# the constructor enters the alternate buffer (screen flash), the device probe
# writes DECRQSS/DECRQM query sequences into the spec output (the stray `$qm`,
# `$q"q`, `p`, `*` bytes), and any synchronous reply read — or an `Application#exec`
# loop — parks forever on a tty nobody is typing into, hanging the run.
#
# Most specs pass `input:`/`output:` explicitly, but the ones that can't do not
# have that option: `Window#switch_terminal` builds its replacement window on
# *fresh default IO* by design, so only this global default keeps it in memory.
# Pinning `Always` makes an interactive run byte-identical to a redirected one.
Crysterm::Config.set "screen.headless", Crysterm::Headless::Always

# When built with -Dremote, let the bridge specs actually open their ports.
{% if flag?(:remote) %}
  Crysterm::Remote.enabled = true
{% end %}
