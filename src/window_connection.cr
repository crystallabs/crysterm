require "./terminal/handshake"

module Crysterm
  # The "connection" seam of a `Window`: everything that binds it to a concrete
  # terminal — its IO, its `Tput`, the input-reading fiber, and the alternate-
  # buffer/mode setup — as opposed to its window-independent content (the
  # widget tree and cell buffer, which survive across connections).
  #
  # Keeping connect/disconnect grouped here would let the connection later be
  # lifted into a separate `Display` object without disturbing the content
  # side. For now it all lives on `Window`.
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

    # Binds a disconnected screen to a new terminal (the given IO, and
    # optionally a spawned `window`), then fully repaints. The widget tree is
    # left intact; only the connection is (re)established. Geometry is taken
    # from the new terminal, so a differently-sized window is handled like a
    # resize.
    def connect(input : IO, output : IO, window : Terminal::Window? = nil) : Nil
      # Tear down any existing connection first, so reattaching never leaks
      # the previous window, its fibers, or its watcher.
      disconnect if @connected
      @owns_io = true
      # Rebinding a `#destroy`ed window is supported, but needs more than
      # clearing the flag — `destroy` also killed one-shot machinery that the
      # connection swap below does not re-establish. See `#revive`.
      revive if @destroyed
      # Mark connected before the swap below so its repaint isn't suppressed
      # (the render fiber no-ops while `@connected` is false).
      @connected = true

      # Re-establish the global-resize subscription if it was dropped.
      @_resize_handler ||= subscribe_global_resize

      # Reattach as `QWindow#screen=`: swap onto a freshly-built device for the
      # new tty (reusing the old device's terminfo + options, sized from the
      # new terminal). `#screen=` enters the alternate buffer, reallocs, and
      # fully repaints; the old device (its closed tput, unwound input fiber)
      # is discarded. Building a new device rather than mutating the old one
      # keeps the previous input fiber from ever touching the new tty. See
      # `Screen#reconnected`.
      self.screen = @screen.reconnected(input, output)

      @window = window

      # Re-apply the window title (sets it on the new terminal via tput).
      @title.try { |t| self.title = t }

      # Restore input listening only if it was active before disconnecting.
      listen if @was_listening
      start_window_watcher
      render
    end

    # Tears down this screen's connection to its terminal: restores the
    # terminal (best-effort), stops the input fiber, closes its IO (if owned)
    # and its spawned window. The screen object, widget tree and content are
    # kept, so it can be re-displayed later via `Window.open(into: self)`.
    # Idempotent.
    def disconnect : Nil
      return unless @connected
      @connected = false
      # The input read fiber now lives on the device; ask it whether it was
      # running so a reattach can restore the prior listening state.
      @was_listening = @screen.listening?

      # Multiple `Window`s can share one `Screen` (one tty). The device-level
      # teardown below (restoring the terminal, stopping the shared input
      # fiber, closing IO, closing the spawned window) must run only when this
      # is the last surface still using the device — otherwise destroying one
      # window would break its siblings. A non-last window just stops painting.
      # `@connected = false` above ensures "live sibling" excludes any window
      # already disconnecting, so the device is restored exactly once.
      if other_live_window_on_device?
        # The departing window may have pinned a hardware cursor shape/color
        # (DECSCUSR / OSC 12) or an OSC title on the shared device; this
        # early-return path skips `restore_terminal`, so nothing would ever
        # undo them and they'd outlive the window. Hand that per-window state
        # back to the surviving active window on the device.
        reassert_sibling_terminal_state
        return
      end

      restore_terminal

      # Closing the input unblocks and ends the key fiber; drop its handle on
      # the device so a later `listen` can start a fresh one.
      if @owns_io
        input.close rescue nil
        output.close rescue nil
      end
      @screen.stop_keys

      @window.try &.close
      @window = nil
    end

    # Brings a `#destroy`ed window back to life so `#connect` can rebind it.
    # Beyond the flags, `destroy` tore down one-shot state that the connection
    # swap does not restore:
    #
    #   * the render and resize loop fibers exited permanently (their stop
    #     flags were set and their doorbells rung) — without respawning them,
    #     every `render` rings `@render_wakeup` with no receiver and the
    #     terminal stays blank;
    #   * the window left `Window.instances` (the at_exit terminal-restore /
    #     sibling-liveness registry, via `Instances#destroy`);
    #   * the window left its `Application`'s routing table, so input would
    #     no longer be dispatched to it.
    #
    # The old loops must have actually exited before the flags are reset:
    # `destroy`'s wake-up may still be in flight, and a woken-but-not-yet-run
    # old fiber would consume — and, the doorbells being coalescing, swallow —
    # the revival repaint's ring, or see the reset flag and keep running
    # alongside its replacement. So this first waits (bounded) for the old
    # fibers to die, and additionally tags each spawn with a generation the
    # loops check, retiring a pathological straggler that outlives the wait.
    # Only called with `@destroyed` true, so a plain disconnect/reconnect never
    # double-spawns the loops.
    private def revive : Nil
      @destroyed = false
      await_loop_exit
      @render_stop = false
      @resize_stop = false
      generation = (@loop_generation += 1)
      @_render_loop_fiber = spawn render_loop(generation)
      @_resize_loop_fiber = spawn(name: "resize_loop") { resize_loop(generation) }
      # Re-register in the global teardown/liveness registry (idempotent).
      bind
      # Re-register with the driving `Application`, if any, so input is routed
      # to this window again (`add` is idempotent; `destroy`'s `remove` keeps
      # the `application` back-link, so the app is still reachable here).
      application.try &.add self
    end

    # Waits (bounded) for the stopped render/resize loop fibers to exit.
    # `destroy` already set their stop flags and rang their doorbells, so each
    # old fiber exits on its next wake-up; this just gives the scheduler time
    # to run them. A fiber that stays alive past the deadline (e.g. blocked
    # writing to a full pipe nobody drains) is abandoned to the generation
    # check, costing at most one swallowed doorbell ring.
    private def await_loop_exit : Nil
      deadline = Time.instant + 1.second
      until loop_fibers_dead? || Time.instant > deadline
        sleep 1.millisecond
      end
    end

    private def loop_fibers_dead? : Bool
      @_render_loop_fiber.try(&.dead?) != false &&
        @_resize_loop_fiber.try(&.dead?) != false
    end

    # Whether another live (connected, not-destroyed) `Window` still shares
    # this window's `Screen` — i.e. tearing the device down now would break a
    # sibling. Uses the global `Window.instances` registry so it holds even
    # for windows sharing a device without an `Application`.
    private def other_live_window_on_device? : Bool
      Window.instances.any? do |w|
        !w.same?(self) && w.connected? && !w.destroyed? && w.screen.same?(@screen)
      end
    end

    # Re-applies the surviving active window's cursor (shape/blink/color) and
    # title after this window departs a shared device (see `#disconnect`'s
    # sibling path). Prefers the `Application`'s active window for the device
    # (routing order), falling back to any live sibling from the global
    # registry. Best-effort: the device may already be half torn down.
    private def reassert_sibling_terminal_state : Nil
      surviving : Window? = nil
      application.try do |app|
        app.windows.reverse_each do |w|
          if !w.same?(self) && w.connected? && !w.destroyed? && w.screen.same?(@screen)
            surviving = w
            break
          end
        end
      end
      surviving ||= Window.instances.find do |w|
        !w.same?(self) && w.connected? && !w.destroyed? && w.screen.same?(@screen)
      end
      surviving.try do |w|
        begin
          w.apply_cursor
          w.title.try { |t| w.tput.title = t }
        rescue
          # Dead fds on a user-closed window raise on write; the sibling's
          # state re-assert must never break the disconnect itself.
        end
      end
    end

    # Runs one terminal-mode teardown step — *block* — only when *enabled*,
    # swallowing any error: a user-closed window leaves dead fds whose writes
    # raise, and restore must press on regardless. Folds the repeated
    # `if @_listened_… begin disable_… rescue end end` guard `restore_terminal`
    # applies to each optionally-enabled input mode.
    private def restore_step(enabled : Bool, & : -> Nil) : Nil
      return unless enabled
      begin
        yield
      rescue
      end
    end

    # Best-effort restore of the terminal to its normal state, split along the
    # surface/device line: this surface tears down its alt buffer (`leave`)
    # and the mouse, then the device (`Screen#restore_input_modes`) turns off
    # the input-mode toggles and restores the tty's line discipline. All steps
    # are guarded because a user-closed window leaves dead fds that raise on write.
    private def restore_terminal : Nil
      restore_step(true) { leave }

      # A no-op on the alt-screen path (`leave` above already disabled the
      # mouse). Matters on the non-alt path, where `leave` early-returns
      # without touching the mouse.
      restore_step(@screen._listened_mouse?) { disable_mouse }

      # Device half: input-mode toggle-offs (keyboard-protocol / bracketed-paste
      # / in-band-resize / color-scheme) plus line-discipline restore.
      @screen.restore_input_modes
    end

    # Spawns a fiber that watches the window's rendezvous socket: routes
    # `WINCH` notifications to a resize, and treats socket EOF as "window was
    # closed". On close it emits `Event::WindowClosed` and disconnects, leaving
    # the screen alive for the handler to reattach or destroy.
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
      # Ignore an app-initiated teardown: `#disconnect` closes the socket
      # itself, waking this watcher on EOF. React only to an external close
      # (user closing the window) while still connected — otherwise a
      # disconnect+reattach would emit WindowClosed, whose handler reattaches,
      # whose teardown emits again, looping forever.
      return unless @connected
      # Ignore a stale watcher whose window was already replaced by a reattach.
      return unless @window == win
      # Disconnect first, so the screen is clean when the handler runs — it
      # may then safely reattach (`Window.open(into: self)`) or destroy it
      # without racing this teardown.
      disconnect
      emit Crysterm::Event::WindowClosed, self
    end

    # Multi-window orchestration (`Application.open` / `.run` / `.exec_all`)
    # lives on `Application`; the per-window connection primitives it drives
    # (`#connect` / `#disconnect` / `#adopt_window`) remain here.

    # :nodoc: exposed for `Application.exec_all`'s shared-quit bookkeeping.
    def destroyed? : Bool
      @destroyed
    end
  end
end
