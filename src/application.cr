require "event_handler"

require "./mixin/instances"
require "./window"

module Crysterm
  # The application — the `QGuiApplication` analogue. Owns the event loop
  # (`#exec` / `.exec_all` / `.run`), the registry of devices (`#screens`) and
  # surfaces (`#windows`), whole-app shutdown, the app-wide "active window", and
  # the clipboard facade.
  #
  # No singleton is enforced: multiple `Application`s may coexist (via
  # `Mixin::Instances`). `Application.global` returns the most-recently-created
  # one, creating one on demand.
  class Application
    include EventHandler
    include Mixin::Instances

    # Surfaces (`Window`s) this application is driving — the per-app routing /
    # "active window" set (≈ `QGuiApplication::allWindows()` scoped to one app).
    # Populated by `#add` (and `Window#listen` self-registers), kept clean by
    # `Window#destroy` calling `#remove`.
    #
    # Deliberately **not** the same registry as class-level `Window.instances`,
    # which tracks *every* surface ever created — including one never attached to
    # an `Application` (`Window.new` enters the alternate buffer in its
    # constructor, before any `#exec`/`#listen`) — and is what `at_exit` walks to
    # restore every terminal on shutdown. Global teardown net vs. per-app routing
    # view; kept separate rather than collapsed into one.
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
    # whose device the clipboard facade talks to. The most-recently added or
    # activated window (see `#activate`).
    def active_window : Window?
      @windows.last?
    end

    # Brings *window* to the front of its device and makes it active: becomes the
    # most-recent window (so `#active_window` / `#active_window_for` route input
    # to it) and is repainted over any sibling sharing the same `Screen`. The
    # toolkit's "raise window" for stacked surfaces. No-op if not registered.
    def activate(window : Window) : Window?
      return unless @windows.includes? window
      @windows.delete window
      @windows << window
      # The frame diff runs against this window's PRIVATE `@olines` (what THIS
      # window last sent); the terminal may currently show a sibling sharing
      # the device, so an unchanged frame would emit zero bytes and the raise
      # would be invisible. Poison the old-frame buffer so the whole surface is
      # re-emitted (the raise counterpart of `Window#screen=`'s enter+realloc).
      window.invalidate_region 0, window.awidth, 0, window.aheight
      # Re-assert per-window terminal state a sibling may have overwritten on
      # the shared device: the hardware cursor shape/blink/color (DECSCUSR /
      # OSC 12 are pushed only from `apply_cursor`, so the raised window would
      # otherwise keep running under the sibling's cursor indefinitely)...
      window.apply_cursor
      # ...and the window title (OSC 0), same structural gap.
      window.title.try { |t| window.tput.title = t }
      window.render
      window
    end

    # Routes one *parsed* input event from *screen* (the device that read it) to
    # the right surface — the `QGuiApplication` dispatch step. The device knows
    # nothing about focus or widgets: it hands its `Tput::InputEvent` here, this
    # resolves the active `Window` on that device, and the window does the
    # mouse/paste/key demux and focus walk (`Window#handle_input`).
    #
    # Also home for **app-global hotkeys**, applied as a *fallback* after the
    # window has had its say. Default quit keys (`q` / Ctrl-Q): a press (never
    # release) on a window with `default_quit_keys?` tears it down and exits —
    # but only when no widget/handler `#accept`ed the key and no widget has
    # grabbed the keyboard, so `q` typed into a reading `LineEdit`/`TextEdit`
    # edits instead of quitting the app. Windows that opt out
    # (`default_quit_keys: false`) never quit here, so their own `q` bindings —
    # or `Application.exec_all`'s graceful quit — run instead.
    def route_input(screen : Screen, e : ::Tput::InputEvent) : Nil
      win = active_window_for(screen)
      return unless win

      # Dispatch to the window first (mirroring how Tab-navigation defers in
      # `_listen_keys`), then quit only if the resulting `KeyPress` came back
      # un-`accepted?` and no widget is grabbing the keyboard (BUGS-F2 #1).
      ev = win.handle_input e

      if ev && win.default_quit_keys? && !win.grab_keys? && !ev.accepted? && quit_key?(ev.char, ev.key)
        # Through `#quit`, not a bare `exit`: handlers get `Event::AboutToQuit`
        # (their only chance to save state), and *every* window this app drives
        # is torn down, not just the one the key arrived on.
        quit
      end
    end

    # Shuts the application down (Qt's `QCoreApplication::quit`): emits
    # `Event::AboutToQuit` so handlers can save state, tears every window down,
    # then exits the process with *status*.
    #
    # This is the app-level quit — the one `Window#application` advertises, and
    # what the default quit keys route through. It is the polite counterpart to
    # a bare `exit`: that skips `AboutToQuit` entirely and leaves teardown to the
    # `at_exit` net (which restores the terminals but runs no application code).
    #
    # NOTE `Application.exec_all` deliberately does *not* use this — it owns quit
    # for its windows and returns normally instead of exiting the process (see
    # that method).
    def quit(status : Int32 = 0) : NoReturn
      emit ::Crysterm::Event::AboutToQuit
      # Iterate a copy: `Window#destroy` calls `#remove`, which mutates
      # `@windows` under an in-place iterator (cf. the `at_exit` net in
      # `crysterm.cr`, same hazard).
      @windows.dup.each { |w| w.destroy unless w.destroyed? }
      exit status
    end

    # Whether *char*/*key* is one of the default quit keys (`q` or `Ctrl-Q`).
    # Factored out so `#route_input`'s hard-exit hotkey and `.exec_all`'s
    # graceful close agree on what "quit" means. Pure, so it's unit-testable
    # without driving the blocking input loop.
    def self.quit_key?(char : Char, key : ::Tput::Key?) : Bool
      char == 'q' || key == ::Tput::Key::CtrlQ
    end

    # :ditto:
    def quit_key?(char : Char, key : ::Tput::Key?) : Bool
      self.class.quit_key? char, key
    end

    # The most-recently-added `Window` shown on *screen*, or `nil`. Mirrors
    # `#active_window` but scoped to one device, so input read on a given tty
    # reaches a window on *that* tty rather than the globally most-recent one
    # (matters once an app drives several windows on distinct devices).
    # Public so a `Window` can ask whether it is the one currently shown on its
    # device (e.g. `Window#on_resize` repaints only the device-active window).
    def active_window_for(screen : Screen) : Window?
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
      # dispatcher (`Screen#listen_keys` -> `#route_input`).
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

      # Headless capture mode: if capture env vars are set, this process is
      # driven by test/example tooling — render one frame, write the requested
      # artifact(s), and return instead of entering the interactive loop.
      return if window.capture_from_env?

      window.render
      window.listen

      # The main loop is currently just a sleep.
      sleep

      # Shouldn't reach for now.
      window.emit ::Crysterm::Event::Detach, window
    end

    # Opens a real terminal emulator window and returns a `Window` driving it.
    #
    # With `into:` nil, a brand-new `Window` is created. Pass an existing
    # (typically disconnected) `Window` as `into:` to re-display it in a fresh
    # window — its widget tree and content are preserved and repainted at the
    # new window's size.
    #
    # `launcher` may be a `Terminal::Launcher`, a backend name (e.g. "kitty",
    # "tmux"), or nil to auto-detect (honoring `$TERMINAL`).
    #
    # Pass `listen: true` to start reading input immediately, so a single spawned
    # window is interactive without a separate `#listen`/`#exec` call (caller
    # still has to keep the process alive, e.g. with `sleep`). Otherwise a
    # freshly opened screen renders but doesn't read input until `#listen` /
    # `#exec` (or `Application.run`); a reattached screen restores whatever
    # listening state it had before disconnecting.
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
    # blocks until none remain — returning cleanly once the last one is gone.
    #
    # This wrapper *owns* quit for its windows: it opts each one out of the
    # app-global hard-exit default (`#route_input`'s `win.destroy; exit`) via
    # `default_quit_keys = false`, so `q`/Ctrl-Q falls through to
    # `Window#handle_input` as `Event::KeyPress`. The handler below then runs a
    # *graceful* close, tearing every managed window down through `finish` so
    # `remaining`/`done` reach zero and `exec_all` returns normally instead of
    # the process hard-exiting mid-loop.
    def self.exec_all(windows : Array(Window)) : Nil
      return if windows.empty?
      remaining = windows.size
      done = Channel(Nil).new(1)
      # Windows already counted as gone. `destroy` emits `Event::Destroy` at
      # most once (guarded by `@destroyed`), but count through a set so a
      # re-emission could never double-decrement `remaining`.
      counted = Set(Window).new

      windows.each do |w|
        # Take over quit from the app-global hotkey (see method doc): the
        # graceful path below, not `route_input`'s `exit`, handles `q`/Ctrl-Q.
        w.default_quit_keys = false
        # Count a window out on ANY teardown path — the quit key below, a
        # `WindowClosed`, or a direct programmatic `w.destroy` (the standard
        # close API). Counting only inside the quit/close handlers left a
        # directly-destroyed window forever uncounted, so `remaining` never
        # reached zero and `done.receive` blocked this method (and the whole
        # process) permanently.
        w.on(Crysterm::Event::Destroy) do
          if counted.add? w
            remaining -= 1
            done.send(nil) if remaining <= 0
          end
        end
        w.on(Crysterm::Event::KeyPress) do |e|
          # Quit only when no widget consumed the key and nothing is grabbing
          # the keyboard — the same guards `#route_input` applies (BUGS-F2 #1).
          # Without them, typing `q` into a reading `LineEdit`/`TextEdit`
          # closed every window.
          next if e.accepted? || w.grab_keys?
          windows.each { |o| o.destroy unless o.destroyed? } if quit_key? e.char, e.key
        end
        w.on(Crysterm::Event::WindowClosed) { w.destroy unless w.destroyed? }
      end

      windows.each do |w|
        w.render
        w.listen
      end

      done.receive
    end

    # The application clipboard ↔ `QClipboard`. `#text=` copies to the active
    # window's terminal via OSC-52; `#request` asks for the system selection
    # (reply lands asynchronously on that device's input), so `#text` is cached.
    class Clipboard
      def initialize(@app : Application)
      end

      # Last value set or received. Refreshed automatically when an OSC-52 read
      # reply arrives (`#request` -> `#refresh_from_terminal`).
      getter text : String = ""

      # Rich payload of the last copy, when it came from a rich-text source
      # (`#set_rich`, e.g. `Widget::TextEdit`); the formatted counterpart of
      # `#text`. Non-nil only while the *most recent* copy was rich: any plain
      # `#text=` clears it, so a paste that prefers the fragment can never
      # resurrect stale formatting over newer plain text (TEXTEDIT.md Phase 3).
      getter fragment : TextDocumentFragment?

      # Sets the clipboard text and copies it to the active window's terminal.
      def text=(value : String) : String
        set_text value
      end

      # Like `#text=`, but the OSC-52 write goes to *window*'s own device (the
      # app-active window when nil). Input routing is per-device without
      # reordering `@windows`, so `active_window` (just `@windows.last`) may be
      # a window on a *different* terminal than the one the copying widget
      # lives on — the copy would land on (and clobber) the wrong terminal's
      # clipboard while the user's terminal keeps its stale content. Callers
      # that know their surface (e.g. a widget's copy_selection) pass it here;
      # the in-process mirror (`#text`) stays app-wide either way.
      def set_text(value : String, window : Window? = nil) : String
        @fragment = nil
        @text = value
        (window || @app.active_window).try &.copy(value)
        value
      end

      # Rich copy: *fragment* for in-process rich paste, plus its plain-text
      # rendering for the terminal (OSC-52 carries text only, so the system
      # clipboard degrades to plain — per plan). *window* routes the device
      # write like `#set_text`.
      def set_rich(fragment : TextDocumentFragment, text : String, window : Window? = nil) : Nil
        set_text text, window
        @fragment = fragment
      end

      # Refreshes the cached text from an OSC-52 *read* reply that just arrived on
      # a device's input. Does NOT re-copy to the terminal — the value came
      # *from* it. Called by `Window#handle_input` on a `Tput::InputEvent#clipboard`.
      # An unchanged value is our own copy echoed back, so the rich payload
      # stays valid; anything else is a fresher external copy and drops it.
      def refresh_from_terminal(value : String) : String
        @fragment = nil unless value == @text
        @text = value
      end

      # Asynchronously requests the system clipboard from *window*'s device
      # (the active window's when nil; OSC-52). The reply arrives later on that
      # device's input. Pass the requesting widget's own window so the query
      # goes to the terminal the user is actually interacting with (see
      # `#set_text`).
      def request(window : Window? = nil) : Nil
        (window || @app.active_window).try &.request_clipboard
      end
    end
  end
end
