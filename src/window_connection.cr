require "./terminal/handshake"

module Crysterm
  # The "connection" seam of a `Window`: everything that binds it to a concrete
  # terminal — its IO, its `Tput`, the input-reading fiber, and the alternate-
  # buffer/mode setup — as opposed to its window-independent content (the
  # widget tree and cell buffer, which survive across connections).
  #
  # It powers two capabilities:
  #   * `Window.open` — spawn a real emulator window and drive it with a `Window`.
  #   * detach/reattach — `#disconnect` a `Window` (closing its window but keeping
  #     the object and its widgets in memory), then `Window.open(into: window)`
  #     to display the same `Window` in a fresh window.
  class Window
    include RestoreGuard

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
    @window : Terminal::EmulatorWindow? = nil

    getter? connected : Bool
    getter window : Terminal::EmulatorWindow?

    # Registers *win* as this (freshly constructed) screen's window and starts
    # watching it. The screen is already connected via its constructor.
    def adopt_window(win : Terminal::EmulatorWindow) : Nil
      @owns_io = true
      @window = win
      start_window_watcher
    end

    # Binds a disconnected screen to a new terminal (the given IO, and
    # optionally a spawned `window`), then fully repaints. The widget tree is
    # left intact; only the connection is (re)established. Geometry is taken
    # from the new terminal, so a differently-sized window is handled like a
    # resize.
    def connect(input : IO, output : IO, window : Terminal::EmulatorWindow? = nil) : Nil
      # Tear down any existing connection first, so reattaching never leaks
      # the previous window, its fibers, or its watcher.
      disconnect if @connected
      # Rebinding a `#destroy`ed window needs more than clearing the flag:
      # `destroy` also killed one-shot machinery the connection swap below does
      # not re-establish.
      revive if @destroyed
      # Mark connected before the swap below so its repaint isn't suppressed
      # (the render fiber no-ops while `@connected` is false).
      @connected = true

      # Re-establish the global-resize subscription if it was dropped.
      @_resize_handler ||= subscribe_global_resize

      # Reattach as `QWindow#screen=`: swap onto a freshly-built device for the
      # new tty (reusing the old device's terminfo + options, sized from the new
      # terminal). `#screen=` enters the alternate buffer, reallocs, and fully
      # repaints. Building a new device rather than mutating the old one keeps
      # the previous input fiber from ever touching the new tty.
      self.screen = @screen.reconnected(input, output)

      # After the swap: `#screen=` clears IO ownership together with the old
      # device's spawned window, but this window owns the fresh IO it was just
      # bound to (and any newly spawned window below).
      @owns_io = true
      @window = window

      # (This window's stored terminal state — hardware cursor, title — is
      # re-applied by `#screen=` above, which the swap on line 72 always runs.)

      # Restore input listening only if it was active before disconnecting.
      start_input if @was_listening
      start_window_watcher
      update
    end

    # Tears down this screen's connection to its terminal: restores the
    # terminal (best-effort), stops the input fiber, closes its IO (if owned)
    # and its spawned window. The screen object, widget tree and content are
    # kept, so it can be re-displayed later via `Window.open(into: self)`.
    # Idempotent.
    def disconnect : Nil
      return unless @connected
      @connected = false
      # The input read fiber lives on the device; ask it whether it was running
      # so a reattach can restore the prior listening state.
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
        # (DECSCUSR / OSC 12) or an OSC title on the shared device. This path
        # skips `restore_terminal`, so hand that per-window state back to the
        # surviving active window instead of letting it outlive the window.
        reassert_sibling_terminal_state
        return
      end

      teardown_device_if_last

      @window.try &.close
      @window = nil
    end

    # Tears down THIS window's device: restores the terminal (best-effort),
    # closes any IO it owns, stops the input fiber, and releases the
    # process-global CSS geometry-anchor claim. Shared by `#disconnect` and
    # `Window#screen=` for the identical ordered sequence they both run when
    # this window is the device's LAST live window — callers must have
    # already established that (see `#other_live_window_on_device?`); a live
    # sibling keeps the device alive via `#reassert_sibling_terminal_state`
    # instead and never reaches here.
    #
    # Deliberately does NOT touch the spawned emulator window (`@window`) or
    # `@owns_io`/`@window` bookkeeping — the two callers differ there:
    # `#disconnect` closes and nils `@window` immediately after; `#screen=`
    # defers the close past the device swap (its stale emulator's watcher
    # must not fire against the new device).
    private def teardown_device_if_last : Nil
      restore_terminal

      # Closing the input unblocks and ends the key fiber; drop its handle on
      # the device so a later `start_input` can start a fresh one.
      if @owns_io
        input.close rescue nil
        output.close rescue nil
      end
      @screen.stop_input
      # The device dies with this window; release any claim it holds on the
      # process-global CSS geometry anchor so a surviving device can take over.
      @screen.release_cell_geometry_anchor
    end

    # Brings a `#destroy`ed window back to life so `#connect` can rebind it,
    # restoring the one-shot state `destroy` tore down: the render and resize
    # loop fibers, membership in `Window.instances`, and the `Application`
    # routing entry.
    #
    # The old loops must have actually exited before the stop flags are reset:
    # an old fiber woken but not yet run would either swallow the revival
    # repaint's (coalescing) doorbell ring or see the reset flag and run
    # alongside its replacement. So this waits (bounded) for them to die, and
    # tags each spawn with a generation the loops check to retire a straggler
    # that outlives the wait. Only called with `@destroyed` true, so a plain
    # disconnect/reconnect never double-spawns the loops.
    private def revive : Nil
      @destroyed = false
      await_loop_exit
      @render_stop = false
      @resize_stop = false
      generation = (@loop_generation += 1)
      @_render_loop_fiber = spawn render_loop(generation)
      @_resize_loop_fiber = spawn(name: "resize_loop") { resize_loop(generation) }
      # Re-register in the global teardown/liveness registry (idempotent).
      register_instance
      # Re-register with the driving `Application`, if any, so input is routed
      # to this window again. `destroy`'s `remove` keeps the `application`
      # back-link, so the app is still reachable here.
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

    # Whether *w* is a live sibling window sharing this window's device: a
    # distinct, connected, not-destroyed `Window` on the same `Screen`. Tearing
    # the device down while such a sibling exists would break it.
    private def live_sibling_on_device?(w : Window) : Bool
      !w.same?(self) && w.connected? && !w.destroyed? && w.screen.same?(@screen)
    end

    # Whether another live (connected, not-destroyed) `Window` still shares
    # this window's `Screen` — i.e. tearing the device down now would break a
    # sibling. Uses the global `Window.instances` registry so it holds even
    # for windows sharing a device without an `Application`.
    private def other_live_window_on_device? : Bool
      Window.instances.any? { |w| live_sibling_on_device? w }
    end

    # Re-applies the surviving active window's cursor (shape/blink/color) and
    # title after this window departs a shared device. Prefers the
    # `Application`'s active window for the device (routing order), falling back
    # to any live sibling from the global registry. Best-effort: the device may
    # already be half torn down.
    private def reassert_sibling_terminal_state : Nil
      surviving : Window? = nil
      application.try do |app|
        app.windows.reverse_each do |w|
          if live_sibling_on_device? w
            surviving = w
            break
          end
        end
      end
      surviving ||= Window.instances.find { |w| live_sibling_on_device? w }
      surviving.try do |w|
        w.reassert_terminal_state
      rescue
        # Dead fds on a user-closed window raise on write; the sibling's
        # state re-assert must never break the disconnect itself.

      end
    end

    # Best-effort restore of the terminal to its normal state, split along the
    # surface/device line: this surface tears down its alt buffer and the mouse,
    # then the device turns off the input-mode toggles and restores the tty's
    # line discipline. All steps are guarded because a user-closed window leaves
    # dead fds that raise on write.
    private def restore_terminal : Nil
      restore_step(true) { leave }

      # A no-op on the alt-screen path (`leave` above already disabled the
      # mouse). Matters on the non-alt path, where `leave` early-returns
      # without touching the mouse.
      restore_step(@screen.mouse_enabled?) { disable_mouse }

      # Device half: input-mode toggle-offs (keyboard-protocol / bracketed-paste
      # / in-band-resize / color-scheme) plus line-discipline restore.
      @screen.restore_input_modes
    end

    # Spawns a fiber that watches the window's rendezvous socket: routes
    # `WINCH` notifications to a resize, and treats socket EOF as "window was
    # closed". On close it emits `Event::WindowClosed` (carrying this `Window`,
    # exactly as `#close` does) and disconnects, leaving the `Window` object
    # alive for the handler to reattach or destroy.
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

    private def on_window_closed(win : Terminal::EmulatorWindow) : Nil
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

    # :nodoc: exposed for `Application.exec_all`'s shared-quit bookkeeping.
    def destroyed? : Bool
      @destroyed
    end

    # Rebuilds this screen on a different terminal type and returns the **new**
    # screen, carrying every top-level widget across. Crysterm loads terminfo
    # once per `Screen`, so changing the terminal at runtime (Blessed's
    # `screen.terminal = '...'`) means a *new* `Screen` with the same widgets.
    # Constructs a new screen on *term*'s terminfo (copying this screen's
    # salient options, but not its IO — the new screen opens fresh, since
    # `#destroy` closes this one's), reparents every widget onto it, destroys
    # this screen, and returns the new one. Re-`update`/`exec` the returned
    # screen.
    #
    # ```
    # screen = screen.switch_terminal "vt100"
    # ```
    def switch_terminal(term : String) : Window
      # Stop the old input fiber FIRST: it is parked in a read on the very tty
      # the replacement opens (fresh default IO — the same STDIN/STDOUT), so it
      # would win the race for probe reply bytes and dispatch them as garbage
      # key events. A reader on unowned STDIN can't be joined (it only wakes on
      # the next bytes), so stopping alone isn't enough — the replacement is
      # also built unprobed (`probe: false`) and probed below, once the old
      # window and its claim on the tty are gone.
      was_listening = @screen.listening?
      @screen.stop_input
      # The replacement gets its own copy of the cursor (incl. its `Style`):
      # `#reparent_onto`'s destroy of THIS window runs `reset_cursor` on its
      # cursor object during `leave`, which would clobber a shared one back to
      # a default block. `_set` is cleared so the new window's `enter` applies
      # the carried shape/blink/color to the NEW terminal.
      carried_cursor = @cursor.dup
      carried_cursor.style = @cursor.style.dup
      carried_cursor._set = false
      replacement = Window.new(
        probe: false,
        terminfo: Unibilium.from_terminal(term),
        title: @title,
        # Carry the pin STATE, not the current size as unconditional pins:
        # passing plain Int32s would set `explicit_width/height` on the new
        # device, so `adopt_terminal_size`/`refresh_size` would no-op forever
        # and the replacement window stop tracking terminal resizes, frozen at
        # the moment-of-switch size. Only an axis that was pinned stays pinned.
        width: (@screen.explicit_width? ? width : nil),
        height: (@screen.explicit_height? ? height : nil),
        # Surface mode/geometry knobs: without these an inline (`alternate:
        # false`) window would come back as a full-screen alt-buffer window
        # with default padding and cursor. The new window re-captures its own
        # inline anchor for `alternate: false` in its initializer.
        alternate: @alternate, auto_grow: @auto_grow, max_height: @max_height,
        padding: @padding, cursor: carried_cursor,
        dock_borders: @dock_borders, dock_contrast: @dock_contrast,
        always_propagated_keys: @always_propagated_keys, always_propagated_chars: @always_propagated_chars,
        propagate_keys: @propagate_keys,
        default_quit_keys: @default_quit_keys, tab_navigation: @tab_navigation,
        optimization: @optimization,
        force_unicode: force_unicode?, full_unicode: @screen.full_unicode?,
        resize_interval: @resize_interval,
      )
      # Carry an explicit runtime glyph-tier pin, like the size pins above:
      # without it the replacement device re-auto-detects and e.g. an Ascii pin
      # (accessibility / broken-font workaround) silently reverts to Unicode
      # chrome. An unpinned tier stays unpinned so detection runs as usual.
      replacement.glyph_tier = glyph_tier if @screen.glyph_tier_explicit?
      # The remaining runtime-settable options the constructor can't take; must
      # run before `start_input` below so its `enable_mouse(focus: send_focus?)`
      # sees the carried value.
      copy_runtime_options_onto replacement
      reparent_onto replacement
      # The deferred device probe (see `probe: false` above), now that no other
      # reader contends for the tty. `Screen#probe` refreshes draw_caps itself;
      # cell geometry (the CSS `px` anchor) and unit'd styles derive from probe
      # results, so re-run those too. Mirrors the ordering `#screen=` uses:
      # stop old input → probe → detect_cell_geometry → start_input.
      replacement.screen.reprobe_and_detect_geometry
      replacement.restyle
      replacement.start_input if was_listening
      replacement
    end

    # Runtime-settable options the constructor can't take. THE single list —
    # add new runtime properties here, not as another inline patch.
    # Deliberately excluded: `grab_keys`
    # (transient grab state managed by the widget grab lifecycle),
    # `render_row_offset`/`anchor_row` (the replacement re-captures its own
    # inline anchor by design), and `application` (documented usage re-`exec`s
    # the returned window, which registers it).
    private def copy_runtime_options_onto(other : Window) : Nil
      other.hyperlinks = hyperlinks
      other.synchronized_output = synchronized_output
      other.send_focus = send_focus?
      other.frame_interval = frame_interval
      other.drag_two_click = drag_two_click?
      other.drag_ghost = drag_ghost?
      other.overflow = overflow
      other.default_attr = default_attr
      other.default_char = default_char
      other.mouse_cursor_shaping = mouse_cursor_shaping
    end

    # Moves every top-level widget from this screen onto *other*, destroys this
    # screen, and returns *other*. The migration half of `#switch_terminal`;
    # also usable on its own to move a whole UI between two existing screens.
    def reparent_onto(other : Window) : Window
      children.dup.each do |child|
        remove child
        other.append child
      end
      destroy
      other
    end
  end
end
