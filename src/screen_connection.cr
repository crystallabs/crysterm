require "./terminal/handshake"

module Crysterm
  # The "connection" seam of a `Screen`: everything that binds it to a concrete
  # terminal — its IO, its `Tput`, the input-reading fiber, and the alternate-
  # buffer/mode setup — as opposed to its window-independent *content* (the
  # widget tree and the cell buffer, which survive across connections).
  #
  # This isolation is deliberate: keeping connect/disconnect grouped here is what
  # would later let the connection be lifted into a separate `Display` object
  # without disturbing the content side. For now it all lives on `Screen`.
  #
  # It powers two capabilities:
  #   * `Screen.open` — spawn a real emulator window and drive it with a `Screen`.
  #   * detach/reattach — `#disconnect` a `Screen` (closing its window but keeping
  #     the object and its widgets in memory), then `Screen.open(into: screen)`
  #     to display the same `Screen` in a fresh window.
  class Screen
    # Whether this screen is currently bound to a live terminal. While false,
    # rendering is suppressed (the render fiber keeps running but does not paint).
    @connected = true

    # Whether this screen owns (and may close) its IO fds. True for screens bound
    # to spawned windows; false for the launching screen (which uses STDIN/STDOUT
    # and must never close them).
    @owns_io = false

    # Set once `#destroy` has run, so it (and `#disconnect`) are idempotent.
    @destroyed = false

    # Whether the input fiber was running when last disconnected, so a reattach
    # (`#connect`) can restore the prior listening state rather than guess.
    @was_listening = false

    # The spawned emulator window backing this screen, if any.
    @window : Terminal::Window? = nil

    getter? connected : Bool
    getter window : Terminal::Window?

    # Opens a real terminal emulator window and returns a `Screen` driving it.
    #
    # With `into:` nil, a brand-new `Screen` is created for the window. Pass an
    # existing (typically disconnected) `Screen` as `into:` to re-display it in a
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
    # `#listen` / `#exec` (or use `Screen.run`); a reattached screen restores
    # whatever listening state it had before disconnecting.
    def self.open(*, launcher : Terminal::Launcher | String | Nil = nil,
                  cols : Int32 = 80, rows : Int32 = 24,
                  title : String? = nil, env : Process::Env = nil,
                  listen : Bool = false, into : Screen? = nil) : Screen
      win = Terminal.spawn_window(launcher: launcher, cols: cols, rows: rows,
        title: title, env: env)

      if screen = into
        screen.connect win.input, win.output, win
      else
        screen = new(input: win.input, output: win.output, title: title)
        screen.adopt_window win
      end

      screen.listen if listen
      screen.emit Crysterm::Event::WindowOpened, screen
      screen
    end

    # Registers *win* as this (freshly constructed) screen's window and starts
    # watching it. Used internally by `Screen.open` for new screens; the screen
    # is already connected via its constructor.
    def adopt_window(win : Terminal::Window) : Nil
      @owns_io = true
      @window = win
      start_window_watcher
    end

    # Binds a disconnected screen to a new terminal (the given IO, and optionally
    # a spawned `window`), then fully repaints. The widget tree is left intact;
    # only the connection is (re)established. Geometry is taken from the new
    # terminal, so a differently-sized window is handled like a resize.
    def connect(input : IO, output : IO, window : Terminal::Window? = nil) : Nil
      # Tear down any existing connection first, so reattaching never leaks the
      # previous window, its fibers, or its watcher.
      disconnect if @connected
      @input = input
      @output = output
      @owns_io = true
      @destroyed = false

      if output.responds_to?(:sync=)
        output.sync = true
      end

      # Build a FRESH Tput for the new connection instead of rebinding the shared
      # one. The previous connection's input fiber may still be unwinding — in
      # particular when a reattach is triggered from inside the key handler, that
      # fiber loops back into `tput.listen` after the handler returns. If it shared
      # this Tput it would read the NEW fd (stealing input) and, on exit, restore
      # cooked mode on the NEW tty (so mouse reports leak as text). Its own Tput
      # keeps it bound to the OLD (now closed) fd. Terminfo is read-only and not
      # owned/freed by Tput, so it is safe to share.
      #
      # `probe: false` is essential here: Tput's constructor otherwise does a live
      # terminal round-trip (writes query sequences, reads the replies). On
      # reattach the new tty has no responder yet, so that read blocks forever —
      # especially when connect runs inside the old key fiber. Capabilities were
      # already detected at construction time, so re-probing is unnecessary.
      @tput = ::Tput.new(
        terminfo: tput.terminfo,
        input: input,
        output: output,
        force_unicode: @force_unicode,
        use_buffer: false,
        probe: false,
      )
      # `reset_screen_size` ioctls the fd, which raises on a non-tty (pipe/file/
      # memory) — tolerate that for headless/redirected use.
      begin
        tput.reset_screen_size
      rescue
      end
      @width = tput.screen.width
      @height = tput.screen.height

      @window = window
      @connected = true

      # Re-establish the global-resize subscription if it was dropped.
      @_resize_handler ||= GlobalEvents.on(::Crysterm::Event::Resize) do |_|
        # In-band resize (DEC 2048), when active, supersedes the SIGWINCH path.
        schedule_resize unless _listened_in_band_resize?
      end

      enter   # alternate buffer + modes + (re)alloc to new size
      realloc # mark every cell dirty so the blank new terminal repaints

      # Re-apply the window title (sets it on the new terminal via tput).
      @title.try { |t| self.title = t }

      # Restore input listening only if it was active before disconnecting.
      listen if @was_listening
      start_window_watcher
      render
    end

    # Tears down this screen's connection to its terminal: restores the terminal
    # (best-effort), stops the input fiber, closes its IO (if owned) and its
    # spawned window. The screen object, its widget tree and content are kept, so
    # it can be re-displayed later via `Screen.open(into: self)`. Idempotent.
    def disconnect : Nil
      return unless @connected
      @connected = false
      @was_listening = !@_keys_fiber.nil?

      restore_terminal

      # Closing the input unblocks and ends the key fiber; nil it so a later
      # `listen` can start a fresh one.
      if @owns_io
        @input.try { |i| i.close rescue nil }
        @output.try { |o| o.close rescue nil }
      end
      @_keys_fiber = nil

      @window.try &.close
      @window = nil
    end

    # Best-effort restore of the terminal to its normal state. All steps are
    # guarded because a user-closed window leaves dead fds that raise on write.
    private def restore_terminal : Nil
      begin
        leave
      rescue
      end

      if @_listened_mouse
        begin
          disable_mouse
        rescue
        end
        @_listened_mouse = false
      end

      if @_listened_keyboard
        begin
          disable_keyboard_protocol
        rescue
        end
      end

      if @_listened_paste
        begin
          disable_bracketed_paste
        rescue
        end
      end

      if @_listened_in_band_resize
        begin
          disable_in_band_resize
        rescue
        end
      end

      if @_listened_color_scheme
        begin
          disable_color_scheme_notifications
        rescue
        end
      end

      # Restore line discipline on a real, still-open tty.
      @input.try do |i|
        begin
          i.cooked! if i.responds_to?(:"cooked!") && i.responds_to?(:"tty?") && i.tty?
        rescue
        end
      end
    end

    # Spawns a fiber that watches the window's rendezvous socket: it routes
    # `WINCH` notifications to a resize, and treats socket EOF as "the window was
    # closed" (typically by the user). On close it emits `Event::WindowClosed`
    # and disconnects, leaving the screen alive for the handler to reattach or
    # destroy.
    private def start_window_watcher : Nil
      win = @window
      return unless win
      sock = win.socket
      spawn do
        while line = (sock.gets rescue nil)
          # Route through the debounced resize path (same as the launching
          # terminal's SIGWINCH) so a drag-resize coalesces into one redraw.
          schedule_resize if line.strip == "WINCH"
        end
        on_window_closed win
      end
    end

    private def on_window_closed(win : Terminal::Window) : Nil
      return if @destroyed
      # Ignore an app-initiated teardown: `#disconnect` closes the socket itself,
      # which wakes this watcher on EOF. We only want to react to an *external*
      # close (the user closing the window), where we are still connected. Without
      # this, an app-driven disconnect+reattach would emit WindowClosed, whose
      # handler reattaches, whose teardown emits again — an endless loop.
      return unless @connected
      # Also ignore a stale watcher whose window has already been replaced by a
      # reattach (so it doesn't tear down the newer, current window).
      return unless @window == win
      # Disconnect FIRST, so the screen is in a clean, disconnected state when the
      # handler runs — a handler may then safely reattach it (`Screen.open(into:
      # self)`) or destroy it without racing this teardown.
      disconnect
      emit Crysterm::Event::WindowClosed, self
    end

    # Convenience: open *windows* emulator windows, build a screen in each via the
    # block, then render+listen them all and block. A `q` / `Ctrl-Q` in any
    # window — or closing any window — tears that one down; the call returns (and
    # the process exits) once the last window is gone.
    def self.run(*, windows : Int32, launcher : Terminal::Launcher | String | Nil = nil,
                 cols : Int32 = 80, rows : Int32 = 24, env : Process::Env = nil,
                 & : Screen, Int32 -> _) : Nil
      screens = (0...windows).map do |i|
        s = open(launcher: launcher, cols: cols, rows: rows,
          title: "Window #{i + 1}", env: env)
        yield s, i
        s
      end
      exec_all screens
    end

    # Renders and starts listening on every screen in *screens*, wires a shared
    # quit (`q` / `Ctrl-Q` in any of them) and per-window close handling, then
    # blocks until none remain.
    def self.exec_all(screens : Array(Screen)) : Nil
      return if screens.empty?
      remaining = screens.size
      done = Channel(Nil).new(1)

      finish = ->(s : Screen) do
        return if s.destroyed?
        s.destroy
        remaining -= 1
        done.send(nil) if remaining <= 0
      end

      screens.each do |s|
        s.on(Crysterm::Event::KeyPress) do |e|
          if e.char == 'q' || e.key == Tput::Key::CtrlQ
            screens.each { |o| finish.call o }
          end
        end
        s.on(Crysterm::Event::WindowClosed) { finish.call s }
      end

      screens.each do |s|
        s.render
        s.listen
      end

      done.receive
    end

    # :nodoc: exposed for `exec_all`'s shared-quit bookkeeping.
    def destroyed? : Bool
      @destroyed
    end
  end
end
