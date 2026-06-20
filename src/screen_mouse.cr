require "gpm"

module Crysterm
  class Screen
    # Mouse support.
    #
    # Crysterm receives mouse input from two possible sources, unified behind a
    # single mechanism:
    #
    #   * **Terminal escape sequences** (xterm SGR/X10) — enabled via `Tput` and
    #     parsed by `Tput::Input#listen`, which hands us a `::Tput::Mouse::Event`.
    #   * **The Linux console `gpm` daemon** — read from `/dev/gpmctl` and
    #     converted to the same `::Tput::Mouse::Event`.
    #
    # Both feed `#dispatch_mouse`, which emits a single `Event::Mouse` on the
    # screen and on the widget under the pointer. Listeners therefore never need
    # to know which source produced an event.

    # Whether mouse listening has been set up for this screen.
    getter? _listened_mouse = false

    # Connection to the `gpm` daemon, if one was established.
    @_gpm : GPM? = nil
    @_gpm_fiber : Fiber?

    # The widget the pointer is currently hovering over (topmost at the pointer
    # position), used to detect hover in/out transitions.
    @_hover : Widget?

    # The widget currently under the pointer (topmost), or `nil` if none. Useful
    # e.g. to confirm, after a delay, that the pointer is still over a widget.
    def hovered : Widget?
      @_hover
    end

    # Turns on xterm mouse reporting for this screen's terminal.
    def enable_mouse
      tput.enable_mouse
    end

    # Turns off xterm mouse reporting and disconnects from `gpm` (if connected).
    def disable_mouse
      tput.disable_mouse
      @_gpm.try &.stop
      @_gpm = nil
      # Drop any lingering hover state so a widget isn't left "hovered".
      @_hover = nil
    end

    # Sets up mouse listening: enables terminal mouse reporting and, when
    # available, also starts reading from the `gpm` console daemon. Both sources
    # are routed through `#dispatch_mouse`.
    #
    # The terminal escape-sequence reports are consumed by the existing input
    # fiber (`#listen_keys`), so this method does not spawn a fiber for them.
    def listen_mouse
      return if @_listened_mouse
      @_listened_mouse = true

      enable_mouse
      listen_gpm
    end

    # Attempts to connect to the `gpm` daemon and, on success, spawns a fiber
    # that converts each `GPM::Event` into a `::Tput::Mouse::Event` and
    # dispatches it. If `gpm` is unavailable (not a Linux console, daemon not
    # running, no socket), this silently does nothing — the terminal
    # escape-sequence path remains fully functional.
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
          dispatch_mouse gpm_to_event(e)
        end
      end
    end

    # Converts a `GPM::Event` (Linux console mouse) into the normalized
    # `::Tput::Mouse::Event`. GPM coordinates are 1-based; we shift them to the
    # 0-based convention used throughout mouse handling.
    private def gpm_to_event(e : GPM::Event) : ::Tput::Mouse::Event
      shift = e.modifiers.shift?
      ctrl = e.modifiers.control?
      meta = e.modifiers.meta?

      button = if e.buttons.left?
                 ::Tput::Mouse::Button::Left
               elsif e.buttons.middle?
                 ::Tput::Mouse::Button::Middle
               elsif e.buttons.right?
                 ::Tput::Mouse::Button::Right
               else
                 ::Tput::Mouse::Button::None
               end

      action = if e.buttons.up?
                 ::Tput::Mouse::Action::WheelUp
               elsif e.buttons.down?
                 ::Tput::Mouse::Action::WheelDown
               elsif e.types.up?
                 ::Tput::Mouse::Action::Up
               elsif e.types.down?
                 ::Tput::Mouse::Action::Down
               else
                 # MOVE or DRAG (or anything else) is reported as movement.
                 ::Tput::Mouse::Action::Move
               end

      ::Tput::Mouse::Event.new(
        action, button,
        (e.x - 1).to_i, (e.y - 1).to_i,
        shift, meta, ctrl, :gpm
      )
    end

    # The single dispatch point for *all* mouse events, regardless of source.
    #
    # Emits an `Event::Mouse` on the screen, then locates the topmost
    # mouse-responsive widget under the pointer (`#widget_at`). If one is found,
    # it emits an `Event::Mouse` on it and then — unless a listener `#accept`ed
    # that event — applies the default, out-of-the-box behaviors:
    #
    #   * **Button press** (`action.down?`) focuses the widget (when it is
    #     focusable and `focus_on_click?`) and emits an `Event::Click`.
    #   * **Wheel** (`action.wheel_up?`/`wheel_down?`) scrolls the widget, or its
    #     nearest scrollable ancestor.
    #
    # A widget that wants to override a default can simply `accept` the
    # `Event::Mouse` in its own handler.
    def dispatch_mouse(ev : ::Tput::Mouse::Event)
      emit ::Crysterm::Event::Mouse.new ev

      w = widget_at ev.x, ev.y

      update_hover w, ev

      return unless w

      me = ::Crysterm::Event::Mouse.new ev
      w.emit me
      return if me.accepted?

      if ev.action.down?
        # Click-to-focus, the GUI-toolkit default. Only focusable widgets are
        # focused; `focus_on_click?` lets a widget opt out (e.g. list items).
        if w.focus_on_click? && w.keyable?
          w.focus
          render
        end
        w.emit ::Crysterm::Event::Click.new
      elsif ev.action.wheel_up?
        scroll_under w, -1
      elsif ev.action.wheel_down?
        scroll_under w, 1
      end
    end

    # Scrolls the first scrollable widget at or above *w* by *offset* lines and
    # re-renders. No-op if neither *w* nor any ancestor is scrollable.
    private def scroll_under(w : Widget, offset : Int32)
      el : Widget? = w
      while el && !el.scrollable?
        el = el.parent
      end
      return unless el
      el.scroll offset
      render
    end

    # Emits hover transition events for the topmost widget under the pointer.
    #
    # We deliberately notify only the topmost widget (*w*): a hover is a visual,
    # foreground notion, so an occluded widget should not appear hovered. A
    # widget that nonetheless wants to know about activity while in the
    # background can subscribe to the screen-level `Event::Mouse`.
    #
    #   * Entering a widget       -> `Event::MouseOver` on it.
    #   * Leaving the prior one   -> `Event::MouseOut`  on it.
    #   * Moving while staying on  -> `Event::MouseMove` (hovering) on it.
    private def update_hover(w : Widget?, ev : ::Tput::Mouse::Event)
      if w != @_hover
        if old = @_hover
          old.emit ::Crysterm::Event::MouseOut.new ev
        end
        @_hover = w
        if w
          w.emit ::Crysterm::Event::MouseOver.new ev
        end
      elsif w && ev.action.move?
        w.emit ::Crysterm::Event::MouseMove.new ev
      end
    end

    # Returns the topmost visible, mouse-responsive widget whose absolute
    # rectangle contains the 0-based point (*x*, *y*), or `nil` if none.
    #
    # Hit-testing follows the actual render/z order rather than registration
    # order: the widget tree is walked in the same depth-first order in which it
    # is painted (`@children` array order; see `Screen#_render`), and the last
    # match wins — i.e. the widget drawn last (on top). This is what makes
    # `Widget#front!` / `Widget#back!` affect which widget the mouse "sees":
    # reordering a widget within its parent's `children` both raises it visually
    # and makes it the hit target, with no separate bookkeeping to keep in sync.
    def widget_at(x, y) : Widget?
      found = nil
      each_descendant do |el|
        next unless el.wants_mouse?
        next unless el.visible?

        left = el.aleft
        top = el.atop
        next unless x >= left && x < left + el.awidth
        next unless y >= top && y < top + el.aheight

        found = el
      end
      found
    end

    # Registers *el* as a widget that wants to receive mouse input. Mirrors
    # `#register_keyable`. If mouse listening is already active, this lazily
    # ensures terminal mouse reporting is on (blessed-style on-demand enabling).
    def register_clickable(el : Widget)
      return if @clickable.includes? el
      el.clickable = true
      @clickable.push el
      enable_mouse if @_listened_mouse
    end
  end
end
