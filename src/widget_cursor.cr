module Crysterm
  class Widget
    # Per-widget terminal cursor.
    #
    # `nil` (the default) means this widget inherits the window's default cursor
    # (`Window#cursor`). Changing any cursor setting (via the methods below or
    # `#cursor!`) creates an override `Cursor` here, which takes precedence over
    # the window default while focused.
    property cursor : Cursor? = nil

    # Returns this widget's own cursor, creating (and enabling) an override on
    # first use, e.g. `widget.cursor!.shape = :line`. Changes take visible effect
    # only while focused; otherwise recorded and applied on focus.
    def cursor! : Cursor
      @cursor ||= Cursor.new
    end

    # This widget's own cursor shape override, or `nil` when it has none (the
    # window default applies). Reads `@cursor` — unlike the old bare-call form,
    # merely reading this never sets anything.
    def cursor_shape : Tput::CursorShape?
      @cursor.try &.shape
    end

    # Sets this widget's cursor shape, overriding the window default while the
    # widget is focused. Leaves blink at its default (off); see `#set_cursor`
    # to set both.
    def cursor_shape=(shape : Tput::CursorShape) : Tput::CursorShape
      set_cursor shape
      shape
    end

    # Sets this widget's cursor shape *and* blink, overriding the window default
    # while the widget is focused. Routes through the window so the hardware vs.
    # artificial decision and (re)rendering are identical to the window cursor.
    #
    # On a detached widget the setting is recorded on the widget's own cursor
    # rather than dropped, and takes effect once attached and focused. Same for
    # the color/show/hide methods below.
    def set_cursor(shape : Tput::CursorShape, *, blink : Bool = false) : Nil
      if s = window?
        s.set_cursor_shape shape, blink: blink, cursor: cursor!
      else
        c = cursor!
        c.shape = shape
        c.blink = blink
        c._set = false
      end
    end

    # This widget's own cursor color override (`"#rrggbb"`), or `nil` when it
    # has none (or is the `-1` "terminal default" sentinel). Reads `@cursor` —
    # unlike the old bare-call form, merely reading this never sets anything.
    def cursor_color : String?
      @cursor.try(&.style.fg).try { |c| Colors.hex(c) if c >= 0 }
    end

    # Sets this widget's cursor color, overriding the window default while the
    # widget is focused. Recorded even while detached (see `#set_cursor`).
    def cursor_color=(color : String?) : String?
      if s = window?
        s.set_cursor_color color, cursor: cursor!
      else
        c = cursor!
        c.style.fg = color
        c._set = true
      end
      color
    end

    # Shows this widget's cursor. Recorded even while detached (see `#cursor_shape`).
    def show_cursor
      if s = window?
        s.show_cursor cursor!
      else
        cursor!._hidden = false
      end
    end

    # Hides this widget's cursor. Recorded even while detached (see `#cursor_shape`).
    def hide_cursor
      if s = window?
        s.hide_cursor cursor!
      else
        cursor!._hidden = true
      end
    end

    # Drops this widget's cursor override, reverting to the window default. If
    # focused, the window default is re-applied right away (and repainted, in
    # case an artificial cursor was being drawn).
    def reset_cursor
      @cursor = nil
      if (s = window?) && s.focused == self
        s.apply_cursor
        s.render if s.renders > 0
      end
    end
  end
end
