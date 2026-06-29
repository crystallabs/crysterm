module Crysterm
  # Device-side input-mode toggles — the optional terminal input enhancements
  # negotiated over `tput` (escape sequences on one tty), with the bookkeeping
  # flag each one needs so teardown (`Window#restore_terminal`) knows what to
  # turn back off. These are pure device concerns (they touch only `tput`/IO),
  # so they live on `Screen`; the owning `Window` delegates the enable/disable
  # methods and the `_listened_*?` predicates straight here.
  #
  # Raw mouse reporting (`enable_mouse` / `@_listened_mouse` / gpm / cursor shape)
  # lives alongside this on the device in `screen_mouse_device.cr`.
  class Screen
    # The input read fiber. There is at most one; `#listen_keys` is idempotent.
    @_keys_fiber : Fiber?

    # Spawns the device's input read fiber: `tput.listen` blocks reading this
    # device's input, parses each byte sequence into a `Tput::InputEvent`, and
    # routes it *up* to the `Application` dispatcher — which picks the active
    # `Window` on this device and hands it the event (`Application#route_input`
    # → `Window#handle_input`). The device knows nothing about focus or widgets.
    #
    # `tput.listen` returns on EOF, so closing the input (`Window#disconnect`)
    # ends this fiber; the rescue swallows the IO error (and the raw-mode-restore
    # error on the now-dead fd) that closing mid-read produces, letting the fiber
    # end quietly. Idempotent: a second call while a fiber exists is a no-op.
    def listen_keys : Nil
      return if @_keys_fiber
      @_keys_fiber = spawn {
        begin
          tput.listen { |e| (application || Application.global).route_input self, e }
        rescue
        end
      }
    end

    # Whether the input read fiber has been started (and not yet dropped). Used
    # by reattach to restore the prior listening state.
    def listening? : Bool
      !@_keys_fiber.nil?
    end

    # Drops the input-fiber handle so a later `#listen_keys` can start a fresh
    # one. The fiber itself ends when its input is closed (see `#listen_keys`);
    # this just clears the reference (`Window#disconnect`).
    def stop_keys : Nil
      @_keys_fiber = nil
    end

    # Whether an enhanced keyboard protocol was enabled for this device (so
    # `#restore_terminal` knows to turn it back off).
    getter? _listened_keyboard = false

    # Turns on the best enhanced keyboard protocol (kitty / modifyOtherKeys) the
    # terminal supports — honoring the `keyboard.exclude` / `keyboard.protocol`
    # config — so `Event::KeyPress#key_event` is populated. With *events* `true`,
    # also requests key releases and lone-modifier presses (e.g. a "tap Alt"
    # gesture); with `false`, only escape-code disambiguation, which never
    # changes how ordinary typing is delivered. A no-op fallback to the legacy
    # baseline on terminals that support neither protocol.
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

    # Enables in-band resize notifications (DEC 2048): the terminal reports size
    # changes through the input stream, feeding the same debounced redraw path
    # as `SIGWINCH` (useful where SIGWINCH is unavailable, e.g. over some PTYs).
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
    # the tty's line discipline (cooked mode). This is the *device* half of
    # teardown; the owning `Window#restore_terminal` calls it after its own
    # surface-half (`leave` the alt buffer, disable the mouse). Every step is
    # guarded: a user-closed window leaves dead fds that raise on write, and the
    # restore must press on regardless.
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

    # Runs *block* only when *enabled*, swallowing any error (dead-fd writes on a
    # user-closed window). Mirrors the surface-side guard in `screen_connection.cr`.
    private def restore_step(enabled : Bool, & : -> Nil) : Nil
      return unless enabled
      begin
        yield
      rescue
      end
    end
  end
end
