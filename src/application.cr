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
    #
    # Deliberately **not** the same registry as class-level `Window.instances`,
    # which tracks *every* surface ever created — including one never attached
    # to an `Application`, since `Window.new` enters the alternate buffer in its
    # constructor — and is what `at_exit` walks to restore every terminal on
    # shutdown. Global teardown net vs. per-app routing view; kept separate.
    getter windows = [] of Window

    def initialize
      register_instance
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
    # activated window.
    def active_window : Window?
      @windows.last?
    end

    # Brings *window* to the front of its device and makes it active: becomes the
    # most-recent window (so input routes to it) and is repainted over any
    # sibling sharing the same `Screen`. The toolkit's "raise window" for stacked
    # surfaces. No-op if not registered.
    def activate(window : Window) : Window?
      return unless @windows.includes? window
      @windows.delete window
      @windows << window
      # A device resize while this window was non-active may not have reached
      # it yet (its debounced resize loop can still be pending); compositing
      # into stale-sized buffers would clip the frame to the old rows/columns.
      # Realloc defensively when the buffer no longer matches the device size.
      window.realloc unless window.buffers_match_device?
      # The frame diff runs against this window's PRIVATE `@flushed_lines` (what THIS
      # window last sent), but the terminal may currently show a sibling sharing
      # the device — an unchanged frame would emit zero bytes and the raise would
      # be invisible. Poison the old-frame buffer to force a full re-emit.
      window.invalidate_region 0, window.awidth, 0, window.aheight
      # Re-assert per-window terminal state (hardware cursor, OSC title) a
      # sibling may have overwritten on the shared device — both are pushed
      # only on (re)takeover, so without this the raised window keeps running
      # under the sibling's cursor and title indefinitely.
      window.reassert_terminal_state
      window.render
      window
    end

    # Routes one *parsed* input event from *screen* (the device that read it) to
    # the right surface — the `QGuiApplication` dispatch step. The device knows
    # nothing about focus or widgets: it hands its `Tput::InputEvent` here, this
    # resolves the active `Window` on that device, and the window does the
    # mouse/paste/key demux and focus walk.
    #
    # Also home for **app-global hotkeys**, applied as a *fallback* after the
    # window has had its say. Default quit keys (`q` / Ctrl-Q): a press (never
    # release) on a window with `default_quit_keys?` quits the application —
    # but only when no widget/handler `#accept`ed the key and no widget has
    # grabbed the keyboard, so `q` typed into a reading `LineEdit`/`TextEdit`
    # edits instead of quitting the app. Windows that opt out never quit here.
    def route_input(screen : Screen, e : ::Tput::InputEvent) : Nil
      # An in-band resize report (DEC 2048) describes the DEVICE, not a
      # surface — and the flag is device-level, so the SIGWINCH path stands
      # down for every window sharing the screen. Delivered only to the active
      # window, siblings would keep stale-sized cell buffers forever and
      # `#activate` would composite them truncated. Broadcast instead: each
      # window debounces on its own resize loop, and `Window#on_resize`
      # already restricts the repaint to the device-active window.
      if e.resize
        @windows.each { |w| w.handle_input e if w.screen.same? screen }
        return
      end

      win = active_window_for(screen)
      return unless win

      # Dispatch to the window first, then quit only if the resulting `KeyPress`
      # came back un-`accepted?` and no widget is grabbing the keyboard.
      ev = win.handle_input e

      if ev && win.default_quit_keys? && quit_gesture?(win, ev)
        # Through `#quit`, not a bare `exit`: handlers get `Event::AboutToQuit`
        # (their only chance to save state), and *every* window this app drives
        # is torn down, not just the one the key arrived on.
        quit
      end
    end

    # Whether `ev` is a quit-eligible key gesture on window `w`: an unconsumed
    # (`!accepted?`) quit key that no keyboard grab is intercepting — so typing
    # `q` into a reading `LineEdit`/`TextEdit` never quits. Callers add any
    # further gate (e.g. `w.default_quit_keys?`) themselves. Shared by the
    # class-method graceful-close path (`.exec_all`) and instance `#route_input`.
    def self.quit_gesture?(w, ev) : Bool
      !ev.accepted? && !w.grab_keys? && quit_key?(ev.char, ev.key)
    end

    # :ditto:
    private def quit_gesture?(w, ev) : Bool
      self.class.quit_gesture? w, ev
    end

    # Channel `#quit` uses to hand its exit status to the `#exec` loop.
    # Buffered so a `quit` with no `exec` blocked on the other end (yet)
    # doesn't deadlock the quitting fiber.
    @quit_channel = Channel(Int32).new(1)

    # Whether an `#exec` loop is currently blocked waiting for `#quit` —
    # decides whether `#quit` signals the loop or (no loop to unwind to)
    # falls back to exiting the process directly.
    @exec_running = false

    # One-shot latch so teardown runs once even when `#quit` re-enters (the
    # windows it destroys call `#remove`, whose last-window-closed hook calls
    # `#quit` again).
    @quit_requested = false

    # Whether destroying the last window ends the `#exec` loop (Qt's
    # `quitOnLastWindowClosed`). Only consulted while `#exec` is blocked, so
    # programs tearing windows down outside an exec loop are unaffected.
    property? quit_on_last_window_closed = true

    # Shuts the application down (Qt's `QCoreApplication::quit`): emits
    # `Event::AboutToQuit` so handlers can save state, tears every window down,
    # then ends the `#exec` loop, which returns *status* to its caller. When no
    # `#exec` loop is running (input started by hand, process kept alive with a
    # bare `sleep`), there is nothing to unwind to, so the process exits with
    # *status* directly.
    #
    # The polite counterpart to a bare `exit`, which skips `AboutToQuit`
    # entirely and leaves teardown to the `at_exit` net (that restores the
    # terminals but runs no application code).
    #
    # NOTE `Application.exec_all` deliberately does *not* use this — it owns quit
    # for its windows and returns normally.
    def quit(status : Int32 = 0) : Nil
      return if @quit_requested
      @quit_requested = true
      emit ::Crysterm::Event::AboutToQuit
      # Iterate a copy: `Window#destroy` calls `#remove`, which mutates
      # `@windows` under an in-place iterator.
      @windows.dup.each { |w| w.destroy unless w.destroyed? }
      if @exec_running
        @quit_channel.send status
      else
        exit status
      end
    end

    # Whether *char*/*key* is one of the default quit keys (`q` or `Ctrl-Q`).
    # Shared so the hard-exit hotkey and the graceful close agree on what
    # "quit" means.
    def self.quit_key?(char : Char, key : ::Tput::Key?) : Bool
      char == 'q' || key == ::Tput::Key::CtrlQ
    end

    # :ditto:
    def quit_key?(char : Char, key : ::Tput::Key?) : Bool
      self.class.quit_key? char, key
    end

    # The most-recently-added `Window` shown on *screen*, or `nil`. Mirrors
    # `#active_window` but scoped to one device, so input read on a given tty
    # reaches a window on *that* tty rather than the globally most-recent one —
    # which matters once an app drives several windows on distinct devices.
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
      # dispatcher.
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
      # Losing the last window ends a blocked `#exec` loop (Qt's
      # `quitOnLastWindowClosed`), so `window.destroy` alone unblocks a program
      # instead of leaving `exec` waiting on a quit that can no longer arrive.
      # Only while `exec` is live — outside it (specs, hand-driven programs)
      # destroying windows must stay side-effect-free. `#quit` re-entry (its
      # teardown lands here for every window) is latched out by
      # `@quit_requested`.
      quit 0 if @exec_running && @windows.empty? && quit_on_last_window_closed?
    end

    # The application clipboard facade ↔ `QGuiApplication::clipboard()`. One
    # logical clipboard per app; the OSC-52 transport runs on the active
    # window's device.
    getter clipboard : Clipboard { Clipboard.new self }

    # Renders *window* and runs the main loop — the `QApplication::exec()` entry.
    # Registers the window, honors headless capture mode, then renders, starts
    # input, and blocks until `#quit` (or, with `#quit_on_last_window_closed?`,
    # until the last window is destroyed), returning the exit status passed to
    # `#quit` — `0` for a last-window-closed exit. The default quit keys route
    # through `#quit`, so a plain `q` makes `exec` return rather than
    # hard-exiting the process.
    def exec(window : Window) : Int32
      # Marked before the first yield point (render/start_input do IO), so a
      # `quit` from a concurrently-scheduled fiber lands in the channel — never
      # in the no-loop-to-unwind-to `exit` branch — even when it runs during
      # this setup.
      @exec_running = true

      add window

      # Headless capture mode: if capture env vars are set, this process is
      # driven by test/example tooling — render one frame, write the requested
      # artifact(s), and return instead of entering the interactive loop.
      if window.run_env_capture
        @exec_running = false
        return 0
      end

      window.render
      window.start_input

      status = @quit_channel.receive
      @exec_running = false
      # Re-arm so a fresh window can be `exec`ed again after a quit (Qt allows
      # re-entering the loop).
      @quit_requested = false
      status
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
    # Pass `start_input: true` to start reading input immediately, so a single
    # spawned window is interactive without a separate `#start_input`/`#exec`
    # call (the caller still has to keep the process alive, e.g. with `sleep`).
    # A reattached screen restores whatever listening state it had before
    # disconnecting.
    def self.open(*, launcher : Terminal::Launcher | String? = nil,
                  cols : Int32 = 80, rows : Int32 = 24,
                  title : String? = nil, env : Process::Env = nil,
                  start_input : Bool = false, into : Window? = nil) : Window
      win = Terminal.spawn_window(launcher: launcher, cols: cols, rows: rows,
        title: title, env: env)

      if window = into
        window.connect win.input, win.output, win
      else
        window = Window.new(input: win.input, output: win.output, title: title)
        window.adopt_window win
      end

      window.start_input if start_input
      window.emit Crysterm::Event::WindowOpened, window
      window
    end

    # Convenience: open *window_count* emulator windows, build a window in each
    # via the block, then render and start input on them all, then block. A `q` / `Ctrl-Q` in
    # any window — or closing any window — tears that one down; the call
    # returns (and the process exits) once the last window is gone.
    def self.run(*, window_count : Int32, launcher : Terminal::Launcher | String? = nil,
                 cols : Int32 = 80, rows : Int32 = 24, env : Process::Env = nil,
                 & : Window, Int32 -> _) : Nil
      wins = (0...window_count).map do |i|
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
    # app-global hard-exit default via `default_quit_keys = false`, so `q`/Ctrl-Q
    # falls through as an `Event::KeyPress`. The handler below then runs a
    # *graceful* close, tearing every managed window down so `remaining`/`done`
    # reach zero and `exec_all` returns normally instead of the process
    # hard-exiting mid-loop.
    def self.exec_all(windows : Array(Window)) : Nil
      return if windows.empty?
      remaining = windows.size
      done = Channel(Nil).new(1)
      # Windows already counted as gone. `destroy` emits `Event::Destroy` at
      # most once, but count through a set so a re-emission could never
      # double-decrement `remaining`.
      counted = Set(Window).new

      windows.each do |w|
        # Take over quit from the app-global hotkey (see method doc).
        w.default_quit_keys = false
        # Count a window out on ANY teardown path — the quit key below, a
        # `WindowClosed`, or a direct programmatic `w.destroy`. Counting only
        # inside the quit/close handlers leaves a directly-destroyed window
        # uncounted, so `remaining` never reaches zero and `done.receive` blocks
        # this method (and the whole process) permanently.
        w.on(Crysterm::Event::Destroy) do
          if counted.add? w
            remaining -= 1
            done.send(nil) if remaining <= 0
          end
        end
        w.on(Crysterm::Event::KeyPress) do |e|
          # Quit only when no widget consumed the key and nothing is grabbing
          # the keyboard — the same guards `#route_input` applies. Without them,
          # typing `q` into a reading `LineEdit`/`TextEdit` closes every window.
          windows.each { |o| o.destroy unless o.destroyed? } if quit_gesture?(w, e)
        end
        w.on(Crysterm::Event::WindowClosed) { w.destroy unless w.destroyed? }
      end

      windows.each do |w|
        w.render
        w.start_input
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
      # reply arrives.
      getter text : String = ""

      # Rich payload of the last copy, when it came from a rich-text source; the
      # formatted counterpart of `#text`. Non-nil only while the *most recent*
      # copy was rich: any plain `#text=` clears it, so a paste that prefers the
      # fragment can never resurrect stale formatting over newer plain text.
      getter fragment : TextDocumentFragment?

      # Sets the clipboard text and copies it to the active window's terminal.
      def text=(value : String) : String
        copy value
      end

      # Like `#text=`, but the OSC-52 write goes to *window*'s own device (the
      # app-active window when nil). Input routing is per-device without
      # reordering `@windows`, so `active_window` (just `@windows.last`) may be
      # a window on a *different* terminal than the copying widget's — the copy
      # would then clobber the wrong terminal's clipboard. Callers that know
      # their surface should pass it; the in-process mirror (`#text`) stays
      # app-wide either way.
      def copy(text : String, window : Window? = nil) : String
        @fragment = nil
        @text = text
        (window || @app.active_window).try &.copy(text)
        text
      end

      # Rich copy: *fragment* for in-process rich paste, plus its plain-text
      # rendering for the terminal (OSC-52 carries text only, so the system
      # clipboard degrades to plain). *window* routes the device write like
      # the plain `#copy`.
      def copy(fragment : TextDocumentFragment, text : String, window : Window? = nil) : Nil
        copy text, window
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
      # `#copy`).
      def request(window : Window? = nil) : Nil
        (window || @app.active_window).try &.request_clipboard
      end
    end
  end
end
