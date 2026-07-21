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
# `misc/control/*` subclass widgets (e.g. `Completer::Popup < Widget::List`), so
# the widget types must already be defined.
require "./misc/**"
require "./layout"
require "./layout/**"
require "./widgets"

# Reactive state (signals + bindings). Must follow the widgets: `bind` references
# `Widget`/`Window`.
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
# HTTP/JSON-RPC bridge. Compiled in only with `-Dremote`, keeping the per-widget
# auto-serialization macro sweep and the HTTP server out of default builds. Even
# when compiled in, the server stays closed until enabled at runtime.
{% if flag?(:remote) %}
  require "./remote/*"
{% end %}

# Main Crysterm module and namespace.
#
# If your code is in its own namespace, you can shorten `Crysterm` to an
# alias of your choosing, e.g. "C":
#
# ```
# require "crysterm"
# alias C = Crysterm
#
# window = C::Window.new title: "hello"
#
# C::Widget::Box.new \
#   parent: window,
#   content: "Hello, World!", style: C::Style.new(bg: "blue", fg: "yellow", border: true),
#   left: "center", top: "center", width: 20, height: 5
#
# # `q` / Ctrl-Q already quit by default, so nothing else is needed.
# window.exec
# ```
module Crysterm
  # Project-wide alias for the "shorthand side" of an enum-valued argument: a
  # single member shorthand (`Symbol` or `String`), or a collection of
  # shorthands for `@[Flags]` enums. Used in initializer signatures as e.g.
  # `Tput::AlignFlag | Shorthands`, with the intended enum listed first.
  alias Shorthands = ::Crystallabs::Helpers::Enums::Shorthands

  # Project-wide alias for the key enum, so user code binding shortcuts can
  # write `Crysterm::Key::Enter` (or plain `Key::Enter` after
  # `include Crysterm`) without ever spelling `Tput::`.
  alias Key = ::Tput::Key

  # Project-wide alias for a primitive scalar attached as arbitrary user
  # payload — `Action#data` (Qt's `QAction::data`) and `Mixin::Data#data`
  # (any widget's `#data`) both carry this. Deliberately narrow (no
  # `YAML::Any`/collections): a payload needing more structure should carry an
  # id here and look the richer object up elsewhere.
  alias UserData = String | Int32 | Int64 | Float64 | Bool

  # Whether this process's STDOUT is a TTY. False if redirected to a file/pipe
  # or there's no controlling terminal (e.g. CI).
  def self.interactive? : Bool
    STDOUT.tty?
  rescue
    false
  end

  # Whether a `Window` constructed without explicit IO should default to a
  # headless (in-memory) connection rather than real `STDIN`/`STDOUT`/`STDERR`.
  # Resolves `screen.headless` config: `Auto` follows the inverse of
  # `interactive?`, `Always`/`Never` force the choice.
  def self.headless? : Bool
    case Config.screen_headless
    in Headless::Always then true
    in Headless::Never  then false
    in Headless::Auto   then !interactive?
    end
  end

  # Builds a `Window`, yields it for UI construction, then runs the main loop —
  # the shortest complete program:
  #
  # ```
  # require "crysterm"
  #
  # Crysterm.run do |w|
  #   w.layout = Crysterm::Layout::Box.new :vertical
  #   Crysterm::Widget::Box.new parent: w, content: "Hello, World!"
  # end
  # ```
  #
  # Blocks until the application quits (`q`/Ctrl-Q out of the box, or any
  # `quit` call) and returns the exit status, so a program can end with
  # `exit Crysterm.run { |w| ... }` when the status matters. Keyword arguments
  # are forwarded to `Window.new`.
  def self.run(**window_options, & : Window ->) : Int32
    window = Window.new(**window_options)
    yield window
    window.exec
  end

  class GlobalEventHub
    include EventHandler
  end

  GlobalEvents = GlobalEventHub.new

  # TODO Should all of these run a proper exit sequence, instead of just exit ad-hoc?
  # (Currently we just call `exit` and count on `at_exit` handlers being invoked, but they
  # are unordered)

  # SIGINT (Ctrl+C) must be trapped: Crystal's default action terminates without
  # running `at_exit`, skipping the terminal-restore chain. Routing it through
  # `exit` (like TERM/QUIT) ensures cleanup runs. It matters during startup —
  # between `Window.new` (enters the alt buffer) and the input fiber establishing
  # raw mode, the tty is still cooked, so Ctrl+C arrives as a real SIGINT and
  # interrupting there would strand the terminal in the alt buffer. Once raw mode
  # is active ISIG is off, Ctrl+C is a keystroke, and this trap is dormant.
  Process.on_terminate do
    exit
  end
  Signal::QUIT.trap do
    exit
  end
  # NOTE No `Signal::KILL.trap`: SIGKILL (like SIGSTOP) is uncatchable — the
  # kernel never delivers it to a handler, so `sigaction` for it just fails
  # silently. `kill -9` unavoidably leaves the terminal unrestored.
  Signal::WINCH.trap do
    # XXX IIRC, urwid has an additional method of tracking resizes. Check it out and add
    # additional support here if necessary.
    GlobalEvents.emit Event::Resize
  end

  # Hands every connected window's terminal back before the process suspends:
  # leaves the alt buffer, turns off mouse reporting/keyboard protocol/paste and
  # restores cooked mode (`Tput#pause` stores a resume continuation). Without it,
  # a suspend leaves the shell prompt inside the app's alt buffer with pointer
  # motion spewing SGR sequences. Best-effort per window: a dead fd must not
  # block the rest.
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
  # stored, then reallocs (invalidating `@flushed_lines` — the terminal no longer shows
  # the pre-suspend frame, so diffing against it would leave shell output as
  # permanent corruption) and repaints.
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
    # iterator and skips windows, leaving their terminal unrestored.
    Window.instances.dup.each &.destroy
  end
end

# If this process was launched as an in-window helper by `Window.open` (env var
# set on the spawned emulator), run the helper loop and exit here before any
# user code runs. No-op in normal runs. Placed at the bottom so the whole
# library is loaded by the time it executes.
Crysterm::Terminal.run_helper_if_requested
