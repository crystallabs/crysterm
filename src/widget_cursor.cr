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

    # Sets this widget's cursor shape, overriding the window default while the
    # widget is focused. Leaves blink at its default (off); see the two-argument
    # `#cursor_shape` to set both.
    def cursor_shape=(shape : Tput::CursorShape) : Tput::CursorShape
      cursor_shape shape
      shape
    end

    # Sets this widget's cursor shape *and* blink, overriding the window default
    # while the widget is focused. Routes through the window so the hardware vs.
    # artificial decision and (re)rendering are identical to the window cursor.
    #
    # On a detached widget the setting is recorded on the widget's own cursor
    # rather than dropped, and takes effect once attached and focused. Same for
    # the color/show/hide methods below.
    def cursor_shape(shape : Tput::CursorShape = Tput::CursorShape::Block, blink : Bool = false)
      if s = window?
        s.cursor_shape shape, blink, cursor!
      else
        c = cursor!
        c.shape = shape
        c.blink = blink
        c._set = false
      end
    end

    # :ditto:
    def cursor_color=(color : String?) : String?
      cursor_color color
      color
    end

    # Sets this widget's cursor color, overriding the window default while the
    # widget is focused. Recorded even while detached (see `#cursor_shape`).
    def cursor_color(color : String? = nil)
      if s = window?
        s.cursor_color color, cursor!
      else
        c = cursor!
        c.style.fg = color
        c._set = true
      end
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
