require "json"

require "event_handler"

require "./version"
require "./macros"
require "./config"
require "./cache"
require "./misc/util/unicode"
require "./event"
require "./drag"
require "./misc/util/helpers"
require "./colors"
require "./kill_ring"
require "./glyphs"
require "./text/text_format"
require "./text/text_fragment"
require "./text/text_block"
require "./text/text_object"
require "./text/text_block_group"
require "./text/text_list"
require "./text/text_table"
require "./text/text_document_fragment"
require "./text/undo_stack"
require "./text/text_cursor"
require "./text/text_document"
require "./text/syntax_highlighter"
require "./text/text_theme"
require "./text/text_tags"
require "./text/text_markdown"
require "./text/text_html"
require "./style/colorizable"
require "./style/sided_geometry"
require "./style/text_attributes"
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
require "./subscription"
require "./overlay/dismiss_session"
require "./overlay/place"
require "pnggif"

require "./mixin/*"

require "./action"
require "./action_group"

require "./cursor"

require "./window"
require "./direct"
require "./plane"
require "./terminal/launchers"
require "./terminal/handshake"
require "./application"

require "./widget"
require "./widget/**"
# The cursor-anchor abstraction references `Widget::Terminal`, so require it
# after the widgets are defined.
require "./cursor_anchor"
require "./capture"
# Loaded after widgets: `misc/control/*` subclass widgets (e.g. `Completer::Popup
# < Widget::List`), so the widget types must already be defined.
require "./misc/**"
require "./layout"
require "./layout/**"
require "./widgets"

# Reactive state (signals + bindings). Loaded after widgets: `bind` references
# `Widget`/`Window`, and `Signal` reuses the `event_handler` machinery and
# `Subscriptions` (already required above).
require "./reactive/signal"
require "./reactive/batch"
require "./reactive/binding"
require "./reactive/bind"
require "./reactive/effect"
require "./reactive/computed"
require "./reactive/observable_list"
require "./reactive/bind_items"

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

  # Hands every connected window's terminal back before the process suspends:
  # leaves the alt buffer, turns off mouse reporting/keyboard protocol/paste,
  # restores cooked mode (`Tput#pause` stores a resume continuation). Without
  # this, an external `kill -TSTP` (or Ctrl+Z in the pre-raw startup window)
  # suspends with the alt buffer active and mouse reporting on — the shell
  # prompt lands inside the app's screen and pointer motion spews SGR
  # sequences. Best-effort per window (a dead fd must not block the rest).
  def self.suspend_terminals : Nil
    Window.instances.dup.each do |w|
      next unless w.connected?
      begin
        w.tput.pause
      rescue
      end
    end
  end

  # Restores every connected window's terminal after the process continues
  # (`SIGCONT`): re-enters the alt buffer/modes via the continuation `#pause`
  # stored, then reallocs (invalidating `@olines` — the terminal no longer
  # shows the pre-suspend frame, so diffing against it would leave shell
  # output as permanent corruption) and repaints.
  def self.resume_terminals : Nil
    Window.instances.dup.each do |w|
      next unless w.connected?
      begin
        w.tput.resume
        w.realloc
        w.render
      rescue
      end
    end
  end

  # SIGTSTP: suspend cleanly. TSTP (unlike SIGSTOP) is catchable, so restore
  # the terminal(s) first, then deliver the real (uncatchable) STOP to self.
  # On `fg`, the shell sends SIGCONT, handled below.
  Signal::TSTP.trap do
    suspend_terminals
    Process.signal Signal::STOP, Process.pid
  end
  Signal::CONT.trap do
    resume_terminals
  end

  at_exit do
    # Iterate a copy: `Window#destroy` calls `@@instances.delete self`, so
    # iterating the live registry in place shifts elements under the index-based
    # iterator and skips some windows — leaving their terminal unrestored
    # (finding 8).
    Window.instances.dup.each &.destroy
  end
end

# If this process was launched as an in-window helper by `Window.open` (env var
# set on the spawned emulator), run the helper loop and exit here before any
# user code runs. No-op in normal runs. Placed at the bottom so the whole
# library is loaded by the time it executes.
Crysterm::Terminal.run_helper_if_requested
