require "./terminal/handshake"

module Crysterm
  # The "connection" seam of a `Window`: everything that binds it to a concrete
  # terminal — its IO, its `Tput`, the input-reading fiber, and the alternate-
  # buffer/mode setup — as opposed to its window-independent *content* (the
  # widget tree and the cell buffer, which survive across connections).
  #
  # This isolation is deliberate: keeping connect/disconnect grouped here is what
  # would later let the connection be lifted into a separate `Display` object
  # without disturbing the content side. For now it all lives on `Window`.
  #
  # It powers two capabilities:
  #   * `Window.open` — spawn a real emulator window and drive it with a `Window`.
  #   * detach/reattach — `#disconnect` a `Window` (closing its window but keeping
  #     the object and its widgets in memory), then `Window.open(into: screen)`
  #     to display the same `Window` in a fresh window.
  class Window
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

    # Registers *win* as this (freshly constructed) screen's window and starts
    # watching it. Used internally by `Application.open` for new screens; the
    # screen is already connected via its constructor.
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
      @owns_io = true
      @destroyed = false

      # Rebuild the device on the new IO pair: a FRESH `Tput` (reusing the read-
      # only terminfo) plus re-derived draw caps, and adopt the new terminal's
      # size. The previous connection's input fiber may still be unwinding, so it
      # must NOT share this Tput (it would steal input on the new fd and restore
      # cooked mode on the new tty); the rebuild gives it a Tput bound to the old
      # (now closed) fd. `probe: false` is essential — the new tty has no
      # responder yet, so a live round-trip would block forever. See
      # `Window#rebuild_connection`.
      @screen.rebuild_connection(input, output)

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
    # it can be re-displayed later via `Window.open(into: self)`. Idempotent.
    def disconnect : Nil
      return unless @connected
      @connected = false
      # The input read fiber now lives on the device; ask it whether it was
      # running so a reattach can restore the prior listening state.
      @was_listening = @screen.listening?

      restore_terminal

      # Closing the input unblocks and ends the key fiber; drop its handle on the
      # device so a later `listen` can start a fresh one.
      if @owns_io
        input.close rescue nil
        output.close rescue nil
      end
      @screen.stop_keys

      @window.try &.close
      @window = nil
    end

    # Runs one terminal-mode teardown step — *block* — only when *enabled*,
    # swallowing any error: a user-closed window leaves dead fds whose writes
    # raise, and the restore must press on regardless. Folds the repeated
    # `if @_listened_… begin disable_… rescue end end` guard that
    # `restore_terminal` applies to each optionally-enabled input mode.
    private def restore_step(enabled : Bool, & : -> Nil) : Nil
      return unless enabled
      begin
        yield
      rescue
      end
    end

    # Best-effort restore of the terminal to its normal state, split along the
    # surface/device line: this surface tears down its alt buffer (`leave`) and
    # the mouse, then the device (`Screen#restore_input_modes`) turns off the
    # input-mode toggles it enabled and restores the tty's line discipline. All
    # steps are guarded because a user-closed window leaves dead fds that raise
    # on write.
    private def restore_terminal : Nil
      restore_step(true) { leave }

      # On the alt-screen path `leave` (above) already disabled the mouse (which
      # cleared the device's `_listened_mouse` flag), so this is a no-op. It still
      # matters on the non-alt path, where `leave` early-returns without touching
      # the mouse: here we own disabling it (`#disable_mouse` clears the flag).
      restore_step(@screen._listened_mouse?) { disable_mouse }

      # Device half: input-mode toggle-offs (keyboard-protocol / bracketed-paste
      # / in-band-resize / color-scheme) plus line-discipline restore.
      @screen.restore_input_modes
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
      # handler runs — a handler may then safely reattach it (`Window.open(into:
      # self)`) or destroy it without racing this teardown.
      disconnect
      emit Crysterm::Event::WindowClosed, self
    end

    # The multi-window orchestration (`Application.open` / `.run` / `.exec_all`)
    # now lives on `Application`; the per-window connection primitives it drives
    # (`#connect` / `#disconnect` / `#adopt_window`) remain here.

    # :nodoc: exposed for `Application.exec_all`'s shared-quit bookkeeping.
    def destroyed? : Bool
      @destroyed
    end
  end
end
