require "gpm"

module Crysterm
  # Device-side mouse transport — the raw-input half of mouse support, on the
  # physical device (`Screen`). Enables/disables terminal mouse reporting,
  # reads the Linux-console `gpm` daemon, and drives the GUI mouse-cursor shape
  # (OSC 22). Parsed mouse events are routed *up* to the `Application`
  # dispatcher exactly like keys; hit-test and hover/drag handling
  # (`#dispatch_mouse`, `#widget_at`, …) stays on `Window` in `window_mouse.cr`.
  #
  # Two input sources feed the same path:
  #
  #   * **Terminal escape sequences** (xterm SGR/X10) — enabled via `Tput` and
  #     parsed by the device read fiber (`Screen#listen_keys`), which yields a
  #     `Tput::InputEvent` carrying a `::Tput::Mouse::Event`.
  #   * **The Linux console `gpm` daemon** — read from `/dev/gpmctl` and
  #     converted to the same `::Tput::Mouse::Event`, then wrapped in a
  #     `Tput::InputEvent`.
  #
  # Both reach `Window#dispatch_mouse` (via `Application#route_input` →
  # `Window#handle_input`), so listeners never need to know the source.
  class Screen
    # Whether mouse listening has been set up for this device.
    getter? _listened_mouse = false

    # Connection to the `gpm` daemon, if one was established.
    @_gpm : GPM? = nil
    @_gpm_fiber : Fiber?

    # Whether widgets may change the GUI mouse-pointer shape (xterm's OSC 22)
    # while hovered. Defaults to the `mouse.cursor_shape` config option (off);
    # set per-device to override. See `Widget#mouse_cursor_shape=`.
    property? mouse_cursor_shape : Bool = Config.mouse_cursor_shape

    # GUI mouse-pointer shape currently pushed via OSC 22, or `nil` for the
    # terminal default. Tracked so we only emit on change and can restore the
    # default on teardown.
    @_mouse_cursor_shape : ::Tput::MouseCursorShape? = nil

    # Requests the GUI mouse-pointer take *shape* while over this terminal, or
    # restores the terminal default when *shape* is `nil`. No-op unless
    # `#mouse_cursor_shape?` is on, or when the request matches what's already
    # applied. Best-effort: only xterm-class terminals honor OSC 22 (see
    # `::Tput::Output#mouse_cursor_shape`); elsewhere silently ignored.
    #
    # Widgets drive this on hover in/out via `Widget#mouse_cursor_shape=`; can
    # also be called directly to set a screen-wide pointer shape.
    def set_mouse_cursor_shape(shape : ::Tput::MouseCursorShape?) : Nil
      return unless mouse_cursor_shape?
      return if shape == @_mouse_cursor_shape
      @_mouse_cursor_shape = shape
      if shape
        tput.mouse_cursor_shape shape
      else
        tput.reset_mouse_cursor_shape
      end
    end

    # Turns on xterm mouse reporting for this device's terminal.
    def enable_mouse
      tput.enable_mouse
    end

    # Turns off xterm mouse reporting and disconnects from `gpm` (if connected),
    # clears the listening flag, and restores the default GUI pointer shape. The
    # surface (`Window#disable_mouse`) wraps this to also drop its hover state.
    def disable_mouse
      tput.disable_mouse
      @_gpm.try &.stop
      @_gpm = nil
      # Stopping the daemon ends `get_event`'s loop so the fiber terminates on
      # its own, but `listen_gpm` guards on `@_gpm_fiber` being nil — leaving
      # the dead handle set would make a later `listen_mouse` silently skip
      # re-establishing the gpm connection.
      @_gpm_fiber = nil
      @_listened_mouse = false
      # No reporting means no further `MouseOut` to revert a hover-set pointer
      # shape, so restore the terminal default now.
      set_mouse_cursor_shape nil
    end

    # Sets up mouse listening: enables terminal mouse reporting and, when
    # available, starts reading from the `gpm` console daemon. Both sources
    # are routed (via `Application#route_input`) to `Window#dispatch_mouse`.
    #
    # Terminal escape-sequence reports are consumed by the device read fiber
    # (`#listen_keys`), so this method does not spawn a fiber for them.
    def listen_mouse
      return if @_listened_mouse
      @_listened_mouse = true

      enable_mouse
      listen_gpm
    end

    # Attempts to connect to the `gpm` daemon and, on success, spawns a fiber
    # that converts each `GPM::Event` into a `::Tput::Mouse::Event`, wraps it in a
    # `Tput::InputEvent`, and routes it to the dispatcher — same path as the
    # terminal escape-sequence reports. If `gpm` is unavailable (not a Linux
    # console, daemon not running, no socket), this silently does nothing.
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
