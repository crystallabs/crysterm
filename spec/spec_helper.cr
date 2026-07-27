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

require "./support/emulator_helpers"
require "./support/media_helpers"
require "./support/grid_helpers"
require "./support/input_helpers"

# Spins the event loop until *block* is truthy or the deadline passes (raising
# so a never-satisfied condition fails loudly rather than hanging forever).
def wait_until(timeout : Time::Span = 2.seconds, poll : Time::Span = 2.milliseconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "wait_until: condition not met within #{timeout}" if Time.instant > deadline
    sleep poll
  end
end

# Like `wait_until` but non-raising: returns whether the condition was met
# within *timeout*. For outcomes that are legitimately racy (e.g. a zombie
# fiber may or may not consume — and drop — the event before the deadline).
def became?(timeout = 200.milliseconds, &) : Bool
  deadline = Time.instant + timeout
  until yield
    return false if Time.instant > deadline
    sleep 2.milliseconds
  end
  true
end

# Temporarily blanks `CSS.default_stylesheet` for the duration of the block,
# restoring the saved stylesheet afterward (even if the block raises).
def without_default_theme(&)
  saved = Crysterm::CSS.default_stylesheet
  Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
  begin
    yield
  ensure
    Crysterm::CSS.default_stylesheet = saved
  end
end

def rgb(name) : Int32
  Crysterm::Colors.convert(name).to_i32
end

# A `Window` bound to in-memory IOs on all three streams, so constructing one
# neither writes `enter`/probe sequences to the real test terminal nor reads
# from it. Omitting *width*/*height* leaves `Window.new`'s own `nil` defaults
# (size resolved from the device) in place.
#
# NOTE the deliberate divergence from the library default: `default_quit_keys`
# is `false` here, while `Config.window_default_quit_keys` (and therefore a bare
# `Window.new`) is `true`. Virtually every spec synthesizes keystrokes, and the
# built-in handler destroys the window and calls `exit` on a `q`/Ctrl-Q — which
# would tear the fixture down (or kill the run) mid-example. Specs that are
# actually *about* the quit keys must ask for them explicitly with
# `default_quit_keys: true`.
def headless_screen(
  width : Int32? = nil,
  height : Int32? = nil,
  *,
  default_quit_keys : Bool = false,
) : Crysterm::Window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height,
    default_quit_keys: default_quit_keys)
end
