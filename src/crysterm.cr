require "json"

require "event_handler"
require "crystallabs-helpers"

require "./version"
require "./macros"
require "./num_util"
require "./formatting"
require "./config"
require "./cache"
require "./attr"
# Before "./sgr": `SGR` has `StringIndex`-restricted overloads.
require "./string_index"
require "./sgr"
require "./unicode"
require "./event"
require "./event_input"
require "./drag"
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
require "./text/text_outline"
require "./text/text_toc"
require "./text/syntax_highlighter"
require "./text/content_palette"
require "./text/text_tags"
require "./text/text_import_base"
require "./text/text_markdown"
require "./text/text_html"
require "./style/colorizable"
require "./style/sided_geometry"
require "./style/text_attributes"
require "./style/light"
require "./style/border"
require "./style/padding"
require "./style/margin"
require "./style/shadow"
require "./style/style"
require "./style/styles"
require "./geometry"
require "./easing"
require "./frame_clock"
require "./junctions"
require "./subscription"
require "./overlay/dismiss_session"
require "./overlay/place"
require "pnggif"

require "./mixin/*"

require "./action"
require "./action_accelerators"
require "./action_group"

require "./window"
require "./direct"
require "./plane"
require "./terminal/capabilities"
require "./terminal/launchers"
require "./terminal/handshake"
require "./application"
require "./clipboard"

require "./widget"
require "./widget/**"
# The cursor-anchor abstraction references `Widget::Terminal`, so require it
# after the widgets are defined.
require "./cursor_anchor"
require "./capture"
require "./dump"
# `control/*` subclass widgets (e.g. `Completer::Popup < Widget::List`), so
# the widget types must already be defined.
require "./control/button_group"
require "./control/completer"
require "./layout"
require "./layout/**"
require "./widgets"
require "./events"

# Reactive state (signals + bindings). Must follow the widgets: `bind` references
# `Widget`/`Window`.
require "./reactive/property"
require "./reactive/batch"
require "./reactive/binding"
require "./reactive/bind"
require "./reactive/effect"
require "./reactive/computed"
require "./reactive/observable_list"
require "./reactive/bind_items"
require "./reactive/bind_action"

require "./style/css/**"

# HTML layout DOM (serialize/load, CSS queries, declarative actions) and the
# remote-control HTTP/JSON-RPC bridge. The in-process layout DOM —
# `#load_layout`, `#to_layout_html`, `#resolve_selector`, `#wire_dom_actions` —
# is part of every build. Only the network surface (the HTTP server and its
# runtime gate) is compiled in with `-Dremote`; even then, the server stays
# closed until enabled at runtime.
require "./dom/dom"
require "./dom/dom_actions"
require "./dom/dom_autoserialize"
require "./dom/dom_loader"
require "./dom/dom_query"
require "./dom/dom_widgets"
require "./dom/inline_css"
{% if flag?(:remote) %}
  require "./remote/dom_http"
  require "./remote/enabled"
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

  # Whether the `log.file` option has been applied to `::Log` (once per process).
  @@log_file_installed = false

  # Points `::Log` at the file the `log.file` option names, once, when it is
  # set. Called when a `Screen` binds a real terminal: from then on standard
  # error *is* the application's screen, so a log line written there (the
  # default backend's) lands over the UI in raw mode — the staircased
  # backtrace a user sees when a handler raises. With the option unset nothing
  # changes; an app wanting another sink sets `::Log` up itself. The backend
  # dispatches synchronously so the last lines before an exit are not lost.
  def self.install_log_file : Nil
    return if @@log_file_installed
    path = Config.log_file
    return if path.empty?
    @@log_file_installed = true
    io = File.open(path, "a")
    io.sync = true
    ::Log.setup :info, ::Log::IOBackend.new(io, dispatcher: ::Log::DispatchMode::Sync)
  end

  # Gives the `log.file` option a default for the application *app*: its
  # per-user cache file, `$XDG_CACHE_HOME/<app>/<app>.log` —
  # `~/.cache/<app>/<app>.log` when `XDG_CACHE_HOME` is unset — created as
  # needed. The default only fills an empty option: a file the user named
  # (the config file, `CRYSTERM_LOG_FILE`, `--log-file`) is kept. Returns the
  # path the option now holds, or `nil` when the directory could not be made,
  # in which case the option stays empty and the standard log setup stands.
  #
  # For an application that wants no backtrace ever written over its screen
  # without asking the user to configure anything; call it before the first
  # `Window`, since `#install_log_file` applies the option when a `Screen`
  # binds the terminal.
  #
  # ```
  # Crysterm.default_log_file "md" # ~/.cache/md/md.log
  # ```
  def self.default_log_file(app : String) : String?
    current = Config.log_file
    return current unless current.empty?
    base = ENV["XDG_CACHE_HOME"]?.presence || File.join(Path.home, ".cache")
    dir = File.join(base, app)
    Dir.mkdir_p dir
    path = File.join(dir, "#{app}.log")
    Config.set "log.file", path
    path
  rescue File::Error
    nil
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
  #
  # For N emulator windows instead of one in-process window, see `Window.run`.
  def self.run(**window_options, & : Window ->) : Int32
    window = Window.new(**window_options)
    yield window
    window.exec
  end
end

# Process-lifecycle glue: `GlobalEvents`, the signal traps, `Crysterm.shutdown`,
# suspend/resume, and the `at_exit` terminal-restore net. Must stay here — after
# the module intro, before the helper hook below — so its top-level effects
# (trap registration, `at_exit` ordering) run in this exact position.
require "./lifecycle"

# If this process was launched as an in-window helper by `Window.open` (env var
# set on the spawned emulator), run the helper loop and exit here before any
# user code runs. No-op in normal runs. Placed at the bottom so the whole
# library is loaded by the time it executes.
Crysterm::Terminal.run_helper_if_requested
