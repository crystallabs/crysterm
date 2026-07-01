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
require "./kill_ring"
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
require "./easing"
require "./frame_clock"
require "./docking"
require "pnggif"

require "./mixin/*"

require "./action"

require "./cursor"

require "./window"
require "./plane"
require "./terminal/launchers"
require "./terminal/handshake"
require "./application"

require "./widget"
require "./widget/**"
require "./capture"
# Loaded after widgets: `misc/control/*` subclass widgets (e.g. `Completer::Popup
# < Widget::List`), so the widget types must already be defined.
require "./misc/**"
require "./layout"
require "./layout/**"
require "./widgets"

require "./style/css/**"

# Remote control: HTML layout DOM (serialize/load, declarative actions) and the
# HTTP/JSON-RPC bridge. Lives in `src/remote/`, compiled in only with `-Dremote`
# (avoids the per-widget auto-serialization macro sweep and HTTP server in
# default builds). Even when compiled in, the server stays closed until enabled
# at runtime (see `Crysterm::Remote`).
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
# s = C::Window.new
# t = C::Widget::Text.new content: "Hello, World!", style: C::Style.new(bg: "blue", fg: "yellow", border: true), left: "center", top: "center", parent: s
#
# s.append t
# s.on(C::Event::KeyPress) { exit }
#
# s.exec
# ```
module Crysterm
  # Project-wide alias for the "shorthand side" of an enum-valued argument: a
  # single member shorthand (`Symbol` or `String`), or a collection of
  # shorthands for `@[Flags]` enums. Used in initializer signatures as e.g.
  # `Tput::AlignFlag | Shorthands`, with the intended enum listed first.
  # See `Crystallabs::Helpers::Enums`.
  alias Shorthands = ::Crystallabs::Helpers::Enums::Shorthands

  # Whether this process's STDOUT is a TTY. False if redirected to a file/pipe
  # or there's no controlling terminal (e.g. CI). Used by `headless?` to decide
  # a `Window` built without explicit IO.
  def self.interactive? : Bool
    STDOUT.tty?
  rescue
    false
  end

  # Whether a `Window` constructed without explicit IO should default to a
  # headless (in-memory) connection rather than real `STDIN`/`STDOUT`/`STDERR`.
  # Resolves `screen.headless` config: `Auto` follows the inverse of
  # `interactive?`, `Yes`/`No` force the choice.
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

  # SIGINT (Ctrl+C) must be trapped: Crystal's default action terminates the
  # process without running `at_exit`, skipping the terminal-restore chain
  # (`at_exit` -> `Window#destroy` -> `#disconnect` -> `#restore_terminal`).
  # Routing it through `exit` (like TERM/QUIT) ensures cleanup runs. Matters
  # most during startup: between `Window.new` (enters alt buffer) and the input
  # fiber establishing raw mode (`#listen`), the tty is still in cooked mode, so
  # Ctrl+C arrives as a real SIGINT rather than a keystroke — interrupting there
  # without this trap leaves the terminal in the alt buffer with raw
  # mode/mouse reporting partially on. Once raw mode is active, ISIG is off and
  # Ctrl+C is handled as a keystroke by the quit keys, making this trap dormant.
  Signal::INT.trap do
    exit
  end
  Signal::TERM.trap do
    exit
  end
  Signal::QUIT.trap do
    exit
  end
  # NOTE No `Signal::KILL.trap`: SIGKILL (like SIGSTOP) is uncatchable — the
  # kernel never delivers it to a handler, so `sigaction` for it just fails
  # silently (cf. `widget_media_video_source.cr`, which kills ffmpeg with
  # SIGKILL precisely because it can't be trapped). `kill -9` unavoidably
  # leaves the terminal unrestored.
  Signal::WINCH.trap do
    # XXX IIRC, urwid has an additional method of tracking resizes. Check it out and add
    # additional support here if necessary.
    GlobalEvents.emit Event::Resize
  end

  at_exit do
    Window.instances.each &.destroy
  end
end

# If this process was launched as an in-window helper by `Window.open` (env var
# set on the spawned emulator), run the helper loop and exit here before any
# user code runs. No-op in normal runs. Placed at the bottom so the whole
# library is loaded by the time it executes.
Crysterm::Terminal.run_helper_if_requested
