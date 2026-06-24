require "json"

require "event_handler"

require "./version"
require "./macros"
require "./config"
require "./misc/util/unicode"
require "./event"
require "./drag"
require "./misc/util/helpers"
require "./colors"
require "./style/colorizable"
require "./style/sided_geometry"
require "./style/border"
require "./style/padding"
require "./style/margin"
require "./style/shadow"
require "./style/style"
require "./style/styles"
require "./rendering"
require "./geometry"
require "./animation"
require "./timer"
require "./docking"
require "pnggif"

require "./mixin/*"

require "./action"

require "./cursor"

require "./screen"
require "./plane"
require "./terminal/launchers"
require "./terminal/handshake"
require "./screen_connection"

require "./widget"
require "./widget/**"
require "./capture"
# Loaded after widgets: `misc/control/*` subclass widgets (e.g. `Completer::Popup
# < Widget::List`), so the widget types must already be defined. The other misc
# helpers only reference widgets inside method bodies, so their order is free.
require "./misc/**"
require "./layout/**"
require "./widgets"

require "./style/css/**"

# Remote control: the HTML layout DOM (serialize/load, declarative actions) and
# the HTTP/JSON-RPC bridge. Everything beyond the cascade's basic `#to_html`
# document lives in `src/remote/` and is compiled in only with `-Dremote`, so a
# default build pays none of its compile cost (notably the per-widget
# auto-serialization macro sweep) and pulls in no HTTP server. Even when
# compiled in, the network server stays closed until enabled at runtime
# (see `Crysterm::Remote`).
{% if flag?(:remote) %}
  require "./remote/*"
{% end %}

# Main Crysterm module and namespace.
#
# If your code is in its own namespace, you can shorten `Crysterm` to an
# alias of your choosing, e.g. "C":
#
# ```
# require "../src/crysterm"
# alias C = Crysterm
#
# s = C::Screen.new
# t = C::Widget::Text.new content: "Hello, World!", style: C::Style.new(bg: "blue", fg: "yellow", border: true), left: "center", top: "center", parent: s
#
# s.append t
# s.on(C::Event::KeyPress) { exit }
#
# s.exec
# ```
module Crysterm
  # Short, project-wide alias for the "shorthand side" of an enum-valued
  # argument: a single member shorthand (`Symbol` or `String`), or a collection
  # of shorthands for `@[Flags]` enums. Used in initializer signatures as e.g.
  # `Tput::AlignFlag | Shorthands`, with the intended enum listed first.
  # See `Crystallabs::Helpers::Enums`.
  alias Shorthands = ::Crystallabs::Helpers::Enums::Shorthands

  # Whether this process is attached to an interactive terminal — i.e. its
  # standard output is a TTY. False when output is redirected to a file or a
  # pipe, or there is no controlling terminal (as on CI). A `Screen` built
  # without explicit IO uses this to decide whether to run `headless?`.
  def self.interactive? : Bool
    STDOUT.tty?
  rescue
    false
  end

  # Whether a `Screen` constructed without explicit IO should default to a
  # headless (in-memory) connection rather than the real `STDIN`/`STDOUT`/
  # `STDERR`. Resolves the `screen.headless` config option: `Auto` (the default)
  # follows the inverse of `interactive?` — non-interactive runs go headless —
  # while `Yes`/`No` force the choice regardless of the terminal.
  def self.headless? : Bool
    case Config.screen_headless
    in Headless::Yes  then true
    in Headless::No   then false
    in Headless::Auto then !interactive?
    end
  end

  class GlobalEventsClass
    include EventHandler
  end

  GlobalEvents = GlobalEventsClass.new

  # TODO Should all of these run a proper exit sequence, instead of just exit ad-hoc?
  # (Currently we just call `exit` and count on `at_exit` handlers being invoked, but they
  # are unordered)

  # SIGINT (Ctrl+C) MUST be trapped: Crystal's default action terminates the
  # process WITHOUT running `at_exit`, so the terminal-restore chain (`at_exit`
  # -> `Screen#destroy` -> `#disconnect` -> `#restore_terminal`, which leaves the
  # alternate buffer, shows the cursor, and disables raw mode + mouse reporting)
  # would never run. Routing it through `exit` (like TERM/QUIT) makes that cleanup
  # fire. This matters most during the startup window: between `Screen.new`
  # (which enters the alternate buffer) and the input fiber establishing raw mode
  # (in `#listen`), the tty is still in cooked mode, so a Ctrl+C is delivered as a
  # real SIGINT rather than a keystroke. A slow-to-build app (e.g. the cracktro
  # demo, which constructs ~a screenful of widgets before `exec`) widens that
  # window; without this trap, interrupting there leaves the terminal in the
  # alternate buffer with raw mode / mouse reporting partially on (garbage on
  # mouse movement, no echo). Once raw mode is active, ISIG is off and Ctrl+C
  # arrives as a keystroke handled by the quit keys, so this trap is dormant then.
  Signal::INT.trap do
    exit
  end
  Signal::TERM.trap do
    exit
  end
  Signal::QUIT.trap do
    exit
  end
  Signal::KILL.trap do
    exit
  end
  Signal::WINCH.trap do
    # XXX IIRC, urwid has an additional method of tracking resizes. Check it out and add
    # additional support here if necessary.
    GlobalEvents.emit Event::Resize
  end

  at_exit do
    Screen.instances.each &.destroy
  end
end

# If this process was launched as an in-window helper by `Screen.open` (env var
# set on the spawned emulator), run the helper loop and exit here — before any
# user code runs. A plain no-op in every normal run. Placed at the very bottom so
# the whole library is loaded by the time it executes.
Crysterm::Terminal.run_helper_if_requested
