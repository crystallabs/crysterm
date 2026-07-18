require "gpm"

module Crysterm
  # Policy for SGR-Pixels (DEC 1016) sub-cell mouse coordinates, the
  # `mouse.pixel_coordinates` config option. Pixel mode replaces the terminal's
  # own cell reporting with pixel reports we divide by the measured cell size,
  # so it is opt-in rather than on by default.
  enum PixelMouse
    Auto # Follow the application's request (`Window#enable_mouse(pixels: :on)`); off if it doesn't ask. Auto-detected support is exposed via `Tput::Features#pixel_mouse?` but not force-enabled
    On   # Always enable pixel coordinates (when the terminal reports a cell size to derive cells from)
    Off  # Never enable pixel coordinates, even if the application asks
  end

  # Device-side mouse transport — the raw-input half of mouse support, on the
  # physical device (`Screen`). Enables/disables terminal mouse reporting,
  # reads the Linux-console `gpm` daemon, and drives the GUI mouse-cursor shape
  # (OSC 22). Parsed mouse events are routed *up* to the `Application`
  # dispatcher exactly like keys; hit-test and hover/drag handling stays on
  # `Window`.
  #
  # Two input sources feed the same path:
  #
  #   * **Terminal escape sequences** (xterm SGR/X10) — enabled via `Tput` and
  #     parsed by the device read fiber.
  #   * **The Linux console `gpm` daemon** — read from `/dev/gpmctl`.
  #
  # Both are normalized to a `::Tput::Mouse::Event` wrapped in a
  # `Tput::InputEvent`, so listeners never need to know the source.
  class Screen
    # Whether mouse listening has been set up for this device.
    getter? mouse_enabled = false

    # Connection to the `gpm` daemon, if one was established.
    @_gpm : GPM? = nil
    @_gpm_fiber : Fiber?

    # Whether widgets may change the GUI mouse-pointer shape (xterm's OSC 22)
    # while hovered. Defaults to the `mouse.cursor_shape` config option (off);
    # set per-device to override.
    property? mouse_cursor_shaping : Bool = Config.mouse_cursor_shape

    # GUI mouse-pointer shape currently pushed via OSC 22, or `nil` for the
    # terminal default. Tracked so we only emit on change and can restore the
    # default on teardown.
    @_mouse_cursor_shape : ::Tput::MouseCursorShape? = nil

    # Requests the GUI mouse-pointer take *shape* while over this terminal, or
    # restores the terminal default when *shape* is `nil`. No-op unless
    # `#mouse_cursor_shaping?` is on, or when the request matches what's already
    # applied. Best-effort: only xterm-class terminals honor OSC 22; elsewhere
    # it is silently ignored.
    def mouse_cursor_shape=(shape : ::Tput::MouseCursorShape?) : Nil
      return unless mouse_cursor_shaping?
      return if shape == @_mouse_cursor_shape
      @_mouse_cursor_shape = shape
      if shape
        tput.mouse_cursor_shape shape
      else
        tput.reset_mouse_cursor_shape
      end
    end

    # Turns on xterm mouse reporting for this device's terminal and, when
    # available, starts reading from the `gpm` console daemon. Escape-sequence
    # reports are consumed by the device read fiber, so no fiber is spawned for
    # them here.
    #
    # The `gpm` connect (and the one-time listening flag) happen at most once —
    # merging what used to be the separate, guarded `listen_mouse` — but the
    # `tput.enable_mouse` re-assert always runs on every call, even when already
    # listening: callers (e.g. `Window#register_clickable`'s on-demand
    # re-enable) rely on being able to re-send the escape sequence without
    # tearing down and reconnecting `gpm`.
    #
    # Pass *pixels* to request SGR-Pixels reporting (DEC 1016), so mouse events
    # carry sub-cell pixel coordinates (`Event::Mouse#px`/`#py`) alongside the
    # usual cell coordinates. The request is gated by the
    # `mouse.pixel_coordinates` config option (`PixelMouse`): `On` forces it,
    # `Off` forbids it, and the default `Auto` honors this *pixels* argument
    # (`PixelMouse::On` here asks for it, `Off`/`Auto` don't).
    #
    # Even when requested it needs the terminal's cell size in pixels to derive
    # cell coordinates; if that's unknown (`0`, common under multiplexers) pixel
    # mode is silently skipped and reporting stays at cell resolution. Whether
    # the terminal actually supports 1016 is auto-detected via DECRQM at startup.
    def enable_mouse(pixels : PixelMouse = :auto) : Nil
      want = case Config.mouse_pixel_coordinates
             in PixelMouse::On   then true
             in PixelMouse::Off  then false
             in PixelMouse::Auto then pixels.on?
             end
      cell = nil
      if want && cell_pixel_width > 0 && cell_pixel_height > 0
        cell = {cell_pixel_width, cell_pixel_height}
      end
      tput.enable_mouse(pixels: cell)

      return if @mouse_enabled
      @mouse_enabled = true
      listen_gpm
    end

    # Turns off xterm mouse reporting and disconnects from `gpm` (if connected),
    # clears the listening flag, and restores the default GUI pointer shape.
    def disable_mouse
      tput.disable_mouse
      @_gpm.try &.stop
      @_gpm = nil
      # The fiber ends on its own once the daemon stops, but the handle must be
      # cleared too: `listen_gpm` guards on it being nil, so a stale one would
      # make a later `enable_mouse` silently skip reconnecting to gpm.
      @_gpm_fiber = nil
      @mouse_enabled = false
      # No reporting means no further `MouseLeave` to revert a hover-set pointer
      # shape, so restore the terminal default now.
      self.mouse_cursor_shape = nil
    end

    # Attempts to connect to the `gpm` daemon and, on success, spawns a fiber
    # that normalizes each `GPM::Event` and routes it to the dispatcher — the
    # same path as the terminal escape-sequence reports. Silently does nothing
    # when `gpm` is unavailable (not a Linux console, daemon not running).
    private def listen_gpm
      return if @_gpm_fiber

      gpm = begin
        GPM.new
      rescue
        nil
      end
      return unless gpm

      @_gpm = gpm
      @_gpm_fiber = spawn do
        while e = gpm.get_event
          (application || Application.global).route_input self,
            ::Tput::InputEvent.new('\0', mouse: gpm_to_event(e))
        end
      end
    end

    # Converts a `GPM::Event` (Linux console mouse) into the normalized
    # `::Tput::Mouse::Event`. GPM coordinates are 1-based; shifted here to the
    # 0-based convention used throughout mouse handling.
    private def gpm_to_event(e : GPM::Event) : ::Tput::Mouse::Event
      button = if e.left?
                 ::Tput::Mouse::Button::Left
               elsif e.middle?
                 ::Tput::Mouse::Button::Middle
               elsif e.right?
                 ::Tput::Mouse::Button::Right
               else
                 ::Tput::Mouse::Button::None
               end

      action = if e.wheel_up?
                 ::Tput::Mouse::Action::WheelUp
               elsif e.wheel_down?
                 ::Tput::Mouse::Action::WheelDown
               elsif e.released?
                 ::Tput::Mouse::Action::Up
               elsif e.pressed?
                 ::Tput::Mouse::Action::Down
               else
                 # MOVE or DRAG (or anything else) is reported as movement.
                 ::Tput::Mouse::Action::Move
               end

      ::Tput::Mouse::Event.new(
        action, button,
        (e.x - 1).to_i, (e.y - 1).to_i,
        e.shift?, e.meta?, e.ctrl?, :gpm
      )
    end
  end
end
