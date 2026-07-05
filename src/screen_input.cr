module Crysterm
  # Device-side input-mode toggles — optional terminal input enhancements
  # negotiated over `tput`, with the bookkeeping flag each needs so teardown
  # (`Window#restore_terminal`) knows what to turn back off. Pure device
  # concerns (touch only `tput`/IO), so they live on `Screen`; the owning
  # `Window` delegates the enable/disable methods and `_listened_*?` here.
  #
  # Raw mouse reporting (`enable_mouse` / `@_listened_mouse` / gpm / cursor shape)
  # lives alongside this on the device in `screen_mouse_device.cr`.
  class Screen
    # The input read fiber. There is at most one; `#listen_keys` is idempotent.
    @_keys_fiber : Fiber?

    # Cooperative stop flag for the input read fiber. `#stop_keys` sets it; the
    # `#listen_keys` loop checks it before dispatching each event so that, once a
    # device is disconnected, no further events are routed to a screen that may
    # already be torn down. The fiber blocked in `tput.listen` still
    # can't be interrupted mid-read without changing `tput`, so it may consume one
    # more byte before it sees the flag and exits — but it will not dispatch it.
    @_keys_stopped = false

    # Spawns the device's input read fiber: `tput.listen` parses each byte
    # sequence into a `Tput::InputEvent` and routes it *up* to the `Application`
    # dispatcher (`Application#route_input` → `Window#handle_input`), which picks
    # the active `Window` on this device. The device itself knows nothing about
    # focus or widgets.
    #
    # `tput.listen` returns on EOF, so closing the input (`Window#disconnect`)
    # ends this fiber; the rescue swallows the IO/raw-mode-restore errors that
    # closing mid-read produces. Idempotent: a second call while a fiber exists
    # is a no-op.
    def listen_keys : Nil
      return if @_keys_fiber
      @_keys_stopped = false
      @_keys_fiber = spawn {
        begin
          tput.listen do |e|
            # Cooperative stop: after `#stop_keys` (device
            # disconnect), drop any further event instead of routing it to a
            # possibly dead screen, and exit the read loop.
            break if @_keys_stopped

            # Isolate user-handler exceptions per event. A single
            # raising key/mouse/drag handler must not unwind `tput.listen` and
            # kill the one input fiber, making the app permanently deaf. Report
            # and keep looping so subsequent events still dispatch.
            begin
              (application || Application.global).route_input self, e
            rescue ex
              ::Log.error(exception: ex) { "Crysterm: input handler raised; continuing input loop" }
            end
          end
        rescue IO::Error
          # Input fd closed mid-read (`Window#disconnect`); normal teardown.
        end
      }
    end

    # Whether the input read fiber has been started (and not yet dropped). Used
    # by reattach to restore prior listening state.
    def listening? : Bool
      !@_keys_fiber.nil?
    end

    # Drops the input-fiber handle so a later `#listen_keys` can start fresh,
    # and raises the cooperative stop flag so the loop (if it is unowned STDIN
    # and thus not ended by a closed fd) stops dispatching to this now-detached
    # screen and exits on its next wake-up. The fiber blocked in
    # `tput.listen` also ends when its input is closed (see `#listen_keys`).
    def stop_keys : Nil
      @_keys_stopped = true
      @_keys_fiber = nil
    end

    # Whether an enhanced keyboard protocol was enabled for this device (so
    # `#restore_terminal` knows to turn it back off).
    getter? _listened_keyboard = false

    # Turns on the best enhanced keyboard protocol (kitty / modifyOtherKeys) the
    # terminal supports — honoring `keyboard.exclude`/`keyboard.protocol` config
    # — so `Event::KeyPress#key_event` is populated. With *events* `true`, also
    # requests key releases and lone-modifier presses (e.g. "tap Alt"); with
    # `false`, only escape-code disambiguation. No-op fallback on terminals
    # supporting neither protocol.
    def enable_keyboard_protocol(events : Bool = false) : ::Tput::KeyboardProtocol
      @_listened_keyboard = true
      tput.enable_keyboard_protocol events
    end

    # Turns the enhanced keyboard protocol back off, restoring the terminal's
    # default keyboard reporting.
    def disable_keyboard_protocol : Nil
      tput.disable_keyboard_protocol
      @_listened_keyboard = false
    end

    # Whether bracketed paste was enabled for this device.
    getter? _listened_paste = false

    # Enables bracketed paste (DEC 2004): pasted text arrives as
    # `Event::Paste` instead of as individual key presses.
    def enable_bracketed_paste : Nil
      @_listened_paste = true
      tput.enable_bracketed_paste
    end

    # Disables bracketed paste.
    def disable_bracketed_paste : Nil
      tput.disable_bracketed_paste
      @_listened_paste = false
    end

    # Whether in-band resize notifications were enabled for this device.
    getter? _listened_in_band_resize = false

    # Enables in-band resize notifications (DEC 2048): reports size changes
    # through the input stream, feeding the same debounced redraw path as
    # `SIGWINCH` (useful where SIGWINCH is unavailable, e.g. over some PTYs).
    def enable_in_band_resize : Nil
      @_listened_in_band_resize = true
      tput.enable_in_band_resize
    end

    # Disables in-band resize notifications.
    def disable_in_band_resize : Nil
      tput.disable_in_band_resize
      @_listened_in_band_resize = false
    end

    # Whether color-scheme notifications were enabled for this device.
    getter? _listened_color_scheme = false

    # Enables light/dark color-scheme change notifications (DEC 2031): theme
    # changes arrive as `Event::ColorScheme`. No-op on unsupported terminals.
    def enable_color_scheme_notifications : Nil
      @_listened_color_scheme = true
      tput.enable_color_scheme_notifications
    end

    # Disables color-scheme change notifications.
    def disable_color_scheme_notifications : Nil
      tput.disable_color_scheme_notifications
      @_listened_color_scheme = false
    end

    # Best-effort turn-off of every input mode this device enabled, then restore
    # the tty's line discipline (cooked mode). The *device* half of teardown;
    # `Window#restore_terminal` calls it after its own surface-half (leave the
    # alt buffer, disable the mouse). Every step is guarded: a user-closed
    # window leaves dead fds that raise on write.
    def restore_input_modes : Nil
      restore_step(_listened_keyboard?) { disable_keyboard_protocol }
      restore_step(_listened_paste?) { disable_bracketed_paste }
      restore_step(_listened_in_band_resize?) { disable_in_band_resize }
      restore_step(_listened_color_scheme?) { disable_color_scheme_notifications }

      # Restore line discipline on a real, still-open tty.
      i = input
      begin
        i.cooked! if i.responds_to?(:"cooked!") && i.responds_to?(:"tty?") && i.tty?
      rescue
      end
    end

    # Runs *block* only when *enabled*, swallowing any error (dead-fd writes on
    # a user-closed window). Mirrors the surface-side guard in `window_connection.cr`.
    private def restore_step(enabled : Bool, & : -> Nil) : Nil
      return unless enabled
      begin
        yield
      rescue
      end
    end
  end
end
