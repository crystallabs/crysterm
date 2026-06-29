require "event_handler"

require "./mixin/instances"
require "./window"

module Crysterm
  # The application — the `QGuiApplication` analogue of the Qt object model (see
  # QT-OBJECT-MODEL-PLAN.md). It owns the event loop (`#exec` / `.exec_all` /
  # `.run`), the registry of devices (`#screens`) and surfaces (`#windows`),
  # whole-app shutdown, the app-wide "active window", and the clipboard facade.
  #
  # No singleton is enforced: multiple `Application`s may coexist (via
  # `Mixin::Instances`). `Application.global` returns the most-recently-created
  # one — "the current app" — creating one on demand. This mirrors
  # `QGuiApplication`'s role without forcing a hard singleton.
  class Application
    include EventHandler
    include Mixin::Instances

    # Surfaces (`Window`s) this application is driving — the per-app routing /
    # "active window" set (≈ `QGuiApplication::allWindows()` scoped to one app).
    # Populated by `#add` (and `Window#listen` self-registers), and kept clean by
    # `Window#destroy`, which calls `#remove`.
    #
    # This is deliberately **not** the same registry as the class-level
    # `Window.instances`: that one tracks *every* surface ever created — including
    # one never attached to an `Application` (a `Window.new` enters the alternate
    # buffer in its constructor, before any `#exec`/`#listen`) — and is what
    # `at_exit` walks to restore every terminal on shutdown. The two serve
    # distinct purposes (global teardown net vs. per-app routing view), so both
    # are kept rather than collapsed into one.
    getter windows = [] of Window

    def initialize
      bind
    end

    # The physical devices (`Screen`s) backing this app's windows ↔
    # `QGuiApplication::screens()`. Derived from the windows, de-duplicated
    # (several windows may share a device).
    def screens : Array(Screen)
      result = [] of Screen
      @windows.each do |w|
        s = w.screen
        result << s unless result.includes? s
      end
      result
    end

    # The app-wide active window — the surface app-level input is routed to, and
    # whose device the clipboard facade talks to. Currently the most-recently
    # added window.
    def active_window : Window?
      @windows.last?
    end

    # Routes one *parsed* input event from *screen* (the device that read it) to
    # the right surface — the `QGuiApplication` dispatch step of the Qt object
    # model (see QT-OBJECT-MODEL-PLAN.md). The device knows nothing about focus or
    # widgets: it hands its `Tput::InputEvent` here, this resolves the active
    # `Window` on that device, and the window does the mouse/paste/key demux and
    # focus walk (`Window#handle_input`).
    #
    # This is also the home for **app-global hotkeys** — intercepted here, before
    # any widget sees the key. The default quit keys (`q` / Ctrl-Q) live here: a
    # press (never a release) on a window that opted into `default_quit_keys?`
    # tears it down and exits, the `QGuiApplication`-level shortcut. Windows that
    # opt out (`default_quit_keys: false`) fall through, so their own widgets'
    # `q` bindings — or a wrapper's graceful quit (`Application.exec_all`) — still
    # run.
    def route_input(screen : Screen, e : ::Tput::InputEvent) : Nil
      win = active_window_for(screen)
      return unless win

      if win.default_quit_keys? && !e.release? &&
         (e.char == 'q' || e.key == ::Tput::Key::CtrlQ)
        win.destroy
        exit
      end

      win.handle_input e
    end

    # The most-recently-added `Window` shown on *screen* (its active surface), or
    # `nil` if none. Mirrors `#active_window` but scoped to one device, so input
    # read on a given tty reaches a window on *that* tty rather than the globally
    # most-recent one (matters once an app drives several windows on distinct
    # devices, e.g. `Application.run(windows: N)`).
    private def active_window_for(screen : Screen) : Window?
      @windows.reverse_each { |w| return w if w.screen.same? screen }
      nil
    end

    # Registers *window* with this application (idempotent), back-links it, and
    # emits `ScreenAdded` the first time a new device appears ↔
    # `QGuiApplication::screenAdded`.
    def add(window : Window) : Window
      return window if @windows.includes? window
      new_device = !screens.includes?(window.screen)
      @windows << window
      window.application = self
      # Back-link the device so its input read fiber can route up to this
      # dispatcher (`Screen#listen_keys` → `#route_input`).
      window.screen.application = self
      emit ::Crysterm::Event::ScreenAdded, window.screen if new_device
      window
    end

    # Removes *window*; emits `ScreenRemoved` when its device is no longer used by
    # any remaining window ↔ `QGuiApplication::screenRemoved`.
    def remove(window : Window) : Nil
      return unless @windows.delete window
      device = window.screen
      emit ::Crysterm::Event::ScreenRemoved, device unless screens.includes? device
    end

    # The application clipboard facade ↔ `QGuiApplication::clipboard()`. One
    # logical clipboard per app; the OSC-52 transport runs on the active window's
    # device (see `Clipboard`).
    getter clipboard : Clipboard { Clipboard.new self }

    # Renders *window* and runs the main loop — the `QApplication::exec()` entry.
    # Registers the window, honors headless capture mode, then renders, starts
    # input, and blocks.
    def exec(window : Window) : Nil
      add window

      # Headless capture mode: if the capture env vars are set this process is
      # being driven by the example/test tooling — render one frame, write the
      # requested artifact(s), and return instead of entering the interactive
      # loop. Lets any standalone program (the `tests/` ports, a user app) be
      # captured without code changes.
      return if window.capture_from_env

      window.render
      window.listen

      # The main loop is currently just a sleep :)
      sleep

      # Shouldn't reach for now
      window.emit ::Crysterm::Event::Detach, window
    end

    # Opens a real terminal emulator window and returns a `Window` driving it.
    #
    # With `into:` nil, a brand-new `Window` is created for the window. Pass an
    # existing (typically disconnected) `Window` as `into:` to re-display it in a
    # fresh window — its widget tree and content are preserved and fully
    # repainted at the new window's size.
    #
    # `launcher` may be a `Terminal::Launcher`, a backend name (e.g. "kitty",
    # "tmux"), or nil to auto-detect (honoring `$TERMINAL`).
    #
    # Pass `listen: true` to start reading input immediately, so a single spawned
    # window is interactive without a separate `#listen`/`#exec` call (the caller
    # still has to keep the process alive, e.g. with `sleep`). When omitted, a
    # freshly opened screen renders but does not read input until you call
    # `#listen` / `#exec` (or use `Application.run`); a reattached screen restores
    # whatever listening state it had before disconnecting.
    def self.open(*, launcher : Terminal::Launcher | String | Nil = nil,
                  cols : Int32 = 80, rows : Int32 = 24,
                  title : String? = nil, env : Process::Env = nil,
                  listen : Bool = false, into : Window? = nil) : Window
      win = Terminal.spawn_window(launcher: launcher, cols: cols, rows: rows,
        title: title, env: env)

      if window = into
        window.connect win.input, win.output, win
      else
        window = Window.new(input: win.input, output: win.output, title: title)
        window.adopt_window win
      end

      window.listen if listen
      window.emit Crysterm::Event::WindowOpened, window
      window
    end

    # Convenience: open *windows* emulator windows, build a window in each via the
    # block, then render+listen them all and block. A `q` / `Ctrl-Q` in any
    # window — or closing any window — tears that one down; the call returns (and
    # the process exits) once the last window is gone.
    def self.run(*, windows : Int32, launcher : Terminal::Launcher | String | Nil = nil,
                 cols : Int32 = 80, rows : Int32 = 24, env : Process::Env = nil,
                 & : Window, Int32 -> _) : Nil
      wins = (0...windows).map do |i|
        w = open(launcher: launcher, cols: cols, rows: rows,
          title: "Window #{i + 1}", env: env)
        yield w, i
        w
      end
      exec_all wins
    end

    # Renders and starts listening on every window in *windows*, wires a shared
    # quit (`q` / `Ctrl-Q` in any of them) and per-window close handling, then
    # blocks until none remain.
    def self.exec_all(windows : Array(Window)) : Nil
      return if windows.empty?
      remaining = windows.size
      done = Channel(Nil).new(1)

      finish = ->(w : Window) do
        return if w.destroyed?
        w.destroy
        remaining -= 1
        done.send(nil) if remaining <= 0
      end

      windows.each do |w|
        w.on(Crysterm::Event::KeyPress) do |e|
          if e.char == 'q' || e.key == Tput::Key::CtrlQ
            windows.each { |o| finish.call o }
          end
        end
        w.on(Crysterm::Event::WindowClosed) { finish.call w }
      end

      windows.each do |w|
        w.render
        w.listen
      end

      done.receive
    end

    # The application clipboard ↔ `QClipboard`. `#text=` copies to the active
    # window's terminal via OSC-52; `#request` asks for the system selection
    # (the reply lands asynchronously on that device's input, like
    # `QClipboard::dataChanged`), so `#text` is a cached value.
    class Clipboard
      def initialize(@app : Application)
      end

      # Last value set or received. Refreshed automatically when an OSC-52 read
      # reply arrives (`#request` → `#refresh_from_terminal`), so after the
      # `Event::Clipboard` fires this reflects the system selection.
      getter text : String = ""

      # Sets the clipboard text and copies it to the active window's terminal.
      def text=(value : String) : String
        @text = value
        @app.active_window.try &.copy(value)
        value
      end

      # Refreshes the cached text from an OSC-52 *read* reply that just arrived on
      # a device's input (≈ `QClipboard::dataChanged`). Does NOT re-copy to the
      # terminal — the value came *from* it. Called by `Window#handle_input` when
      # it routes a `Tput::InputEvent#clipboard` reply.
      def refresh_from_terminal(value : String) : String
        @text = value
      end

      # Asynchronously requests the system clipboard from the active window's
      # device (OSC-52). The reply arrives later on that device's input.
      def request : Nil
        @app.active_window.try &.request_clipboard
      end
    end
  end
end
