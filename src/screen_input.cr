module Crysterm
  # Shared best-effort teardown-step guard for the two sides of a connection.
  # Runs one terminal-mode teardown step — *block* — only when *enabled*,
  # swallowing any error: a user-closed window leaves dead fds whose writes
  # raise, and restore must press on regardless. Must be defined before any
  # `include RestoreGuard` resolves.
  module RestoreGuard
    private def restore_step(enabled : Bool, & : -> Nil) : Nil
      return unless enabled
      begin
        yield
      rescue
      end
    end
  end

  # Device-side input-mode toggles — optional terminal input enhancements
  # negotiated over `tput`, each with the bookkeeping flag teardown needs to
  # know what to turn back off. Pure device concerns (they touch only
  # `tput`/IO), so they live on `Screen`; the owning `Window` delegates here.
  class Screen
    include RestoreGuard

    # The input read fiber handle. Records *intent* — set by `#start_input`,
    # cleared only by `#stop_input` — so it survives the fiber itself ending on
    # EOF or a closed fd (`#listening?` must keep answering "input was started
    # and not stopped" for probe gating and listening-state handovers).
    # Liveness is tracked separately via `@_keys_done_gen`.
    @_keys_fiber : Fiber?

    # Cooperative-cancel generation for the input read fiber. Each spawn
    # captures the then-current value; stopping (and each respawn) bumps it, so
    # a fiber whose value no longer matches drops its event and exits rather
    # than routing to a possibly torn-down screen. Must stay a generation, not a
    # boolean: a stop-then-listen cycle would otherwise "un-cancel" a previous
    # fiber still blocked in `tput.listen` (unowned STDIN survives a disconnect,
    # so it only wakes on its next event), leaving two readers interleaving on
    # one fd. A stale fiber may still consume one final event before it notices
    # the mismatch — but it will not dispatch it.
    @_keys_gen = 0_u64

    # Highest generation whose read fiber has finished (its `tput.listen`
    # returned on EOF or the fd closed under it). When it has caught up with
    # `@_keys_gen`, the current fiber is done: `#input_fiber?` stops handing
    # out the dead fiber and `#start_input` starts a fresh generation instead
    # of no-opping.
    @_keys_done_gen = 0_u64

    # Whether the current input-fiber generation is still running (a stopped
    # or never-started device has no live fiber either way).
    private def input_fiber_live? : Bool
      @_keys_done_gen < @_keys_gen
    end

    # Spawns the device's input read fiber: `tput.listen` parses each byte
    # sequence into a `Tput::InputEvent` and routes it *up* to the `Application`
    # dispatcher, which picks the active `Window` on this device. The device
    # itself knows nothing about focus or widgets.
    #
    # `tput.listen` returns on EOF, so closing the input ends this fiber; the
    # handle (and `#listening?`) stays set, and a later call here — e.g. after
    # swapping in a fresh input IO — starts a new fiber. Idempotent while the
    # fiber is live: a second call then is a no-op.
    def start_input : Nil
      return if @_keys_fiber && input_fiber_live?
      gen = (@_keys_gen += 1)
      @_keys_fiber = spawn do
        tput.listen do |e|
          # Cooperative cancel on a stale generation. MUST precede dispatch,
          # or a zombie fiber double-dispatches its last event.
          break if @_keys_gen != gen

          # Isolate user-handler exceptions per event: one raising handler
          # must not unwind `tput.listen` and kill the only input fiber,
          # leaving the app permanently deaf.
          begin
            (application || Application.global).route_input self, e
          rescue ex
            ::Log.error(exception: ex) { "Crysterm: input handler raised; continuing input loop" }
          end
        end
      rescue IO::Error
        # Input fd closed mid-read; normal teardown. The raise comes from
        # `tput.listen`'s own blocking read (between block invocations), so
        # the rescue must wrap the `listen` call itself — a block-body rescue
        # never sees it and the fiber dies with an unhandled-exception
        # backtrace on the launching terminal.
      ensure
        # Record completion (monotonic: a stale generation ending late must
        # not mask a newer, still-live one). The handle itself stays set — it
        # is intent state, dropped only by `#stop_input`.
        @_keys_done_gen = gen if gen > @_keys_done_gen
      end
    end

    # Whether input reading was started (and not stopped) on this device.
    # Intent state: stays `true` even after the read fiber itself ended on
    # EOF/closed fd — probe gating and listening-state handovers depend on
    # that. Use `#input_fiber?` for liveness.
    def listening? : Bool
      !@_keys_fiber.nil?
    end

    # The device's *live* input read fiber, or `nil` when there is none —
    # including when the last fiber already finished on EOF/closed fd, so a
    # dead fiber is never handed out. Exposed so a fiber-blocking call can
    # refuse to run on it — key delivery stops for as long as that fiber is
    # parked.
    def input_fiber? : Fiber?
      @_keys_fiber if input_fiber_live?
    end

    # Drops the input-fiber handle so a later `#start_input` can start fresh,
    # and bumps the cancel generation so a loop not already ended by a closed fd
    # (i.e. on unowned STDIN) stops dispatching to this now-detached screen and
    # exits on its next wake-up — staying cancelled even if `#start_input`
    # re-arms meanwhile.
    def stop_input : Nil
      @_keys_gen += 1
      @_keys_fiber = nil
    end

    # Whether an enhanced keyboard protocol was enabled for this device (so
    # teardown knows to turn it back off).
    getter? keyboard_protocol_enabled = false

    # Level of enhanced keyboard reporting `#enable_keyboard_protocol` requests.
    # `Disambiguate` is escape-code disambiguation only; `Events` additionally
    # requests key releases and lone-modifier presses (e.g. "tap Alt").
    enum KeyboardReporting
      Disambiguate
      Events
    end

    # Turns on the best enhanced keyboard protocol (kitty / modifyOtherKeys) the
    # terminal supports — honoring `keyboard.exclude`/`keyboard.protocol` config
    # — so `Event::KeyPress#key_event` is populated. With *level* `Events`, also
    # requests key releases and lone-modifier presses (e.g. "tap Alt"); with
    # `Disambiguate`, only escape-code disambiguation. No-op fallback on
    # terminals supporting neither protocol.
    def enable_keyboard_protocol(level : KeyboardReporting = :disambiguate) : ::Tput::KeyboardProtocol
      @keyboard_protocol_enabled = true
      tput.enable_keyboard_protocol level.events?
    end

    # Turns the enhanced keyboard protocol back off, restoring the terminal's
    # default keyboard reporting.
    def disable_keyboard_protocol : Nil
      tput.disable_keyboard_protocol
      @keyboard_protocol_enabled = false
    end

    # Whether bracketed paste was enabled for this device.
    getter? bracketed_paste_enabled = false

    # Enables bracketed paste (DEC 2004): pasted text arrives as
    # `Event::Paste` instead of as individual key presses.
    def enable_bracketed_paste : Nil
      @bracketed_paste_enabled = true
      tput.enable_bracketed_paste
    end

    # Disables bracketed paste.
    def disable_bracketed_paste : Nil
      tput.disable_bracketed_paste
      @bracketed_paste_enabled = false
    end

    # Whether in-band resize notifications were enabled for this device.
    getter? in_band_resize_enabled = false

    # Enables in-band resize notifications (DEC 2048): reports size changes
    # through the input stream, feeding the same debounced redraw path as
    # `SIGWINCH` (useful where SIGWINCH is unavailable, e.g. over some PTYs).
    def enable_in_band_resize : Nil
      @in_band_resize_enabled = true
      tput.enable_in_band_resize
    end

    # Disables in-band resize notifications.
    def disable_in_band_resize : Nil
      tput.disable_in_band_resize
      @in_band_resize_enabled = false
    end

    # Whether color-scheme notifications were enabled for this device.
    getter? color_scheme_notifications_enabled = false

    # Enables light/dark color-scheme change notifications (DEC 2031): theme
    # changes arrive as `Event::ColorSchemeChanged`. No-op on unsupported terminals.
    def enable_color_scheme_notifications : Nil
      @color_scheme_notifications_enabled = true
      tput.enable_color_scheme_notifications
    end

    # Disables color-scheme change notifications.
    def disable_color_scheme_notifications : Nil
      tput.disable_color_scheme_notifications
      @color_scheme_notifications_enabled = false
    end

    # Best-effort turn-off of every input mode this device enabled, then restore
    # the tty's line discipline (cooked mode). The *device* half of teardown,
    # run after the surface half (leaving the alt buffer, disabling the mouse).
    # Every step is guarded: a user-closed window leaves dead fds that raise on
    # write.
    def restore_input_modes : Nil
      restore_step(keyboard_protocol_enabled?) { disable_keyboard_protocol }
      restore_step(bracketed_paste_enabled?) { disable_bracketed_paste }
      restore_step(in_band_resize_enabled?) { disable_in_band_resize }
      restore_step(color_scheme_notifications_enabled?) { disable_color_scheme_notifications }

      # Restore line discipline on a real, still-open tty.
      i = input
      begin
        i.cooked! if i.responds_to?(:"cooked!") && i.responds_to?(:"tty?") && i.tty?
      rescue
      end
    end
  end
end
