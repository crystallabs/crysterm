module Crysterm
  class Widget
    # Per-widget terminal cursor.
    #
    # `nil` (the default) means this widget inherits the window's default cursor
    # (`Window#cursor`). Changing any cursor setting (via the methods below or
    # `#cursor!`) creates an override `Cursor` here, which takes precedence over
    # the window default while focused (resolved in `Window#active_cursor`).
    property cursor : Cursor? = nil

    # Returns this widget's own cursor, creating (and enabling) an override on
    # first use, e.g. `widget.cursor!.shape = :line`. Changes take visible effect
    # only while focused; otherwise recorded and applied on focus.
    def cursor! : Cursor
      @cursor ||= Cursor.new
    end

    # Sets this widget's cursor shape (and blink), overriding the window default
    # while the widget is focused. Routes through the window so the hardware vs.
    # artificial decision and (re)rendering are identical to the window cursor.
    def cursor_shape(shape : Tput::CursorShape = Tput::CursorShape::Block, blink : Bool = false)
      window?.try &.cursor_shape shape, blink, cursor!
    end

    # Sets this widget's cursor color, overriding the window default while the
    # widget is focused.
    def cursor_color(color : String? = nil)
      window?.try &.cursor_color color, cursor!
    end

    # Shows this widget's cursor.
    def show_cursor
      window?.try &.show_cursor cursor!
    end

    # Hides this widget's cursor.
    def hide_cursor
      window?.try &.hide_cursor cursor!
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
