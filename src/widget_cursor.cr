module Crysterm
  class Widget
    # Per-widget terminal cursor.
    #
    # `nil` (the default) means this widget inherits the screen's default cursor
    # (`Screen#cursor`). As soon as any cursor setting is changed on the widget
    # — via the methods below or via `#cursor!` — an override `Cursor` is created
    # and stored here; while the widget is focused it takes precedence over the
    # screen default (the resolution happens in `Screen#active_cursor`).
    property cursor : Cursor? = nil

    # Returns this widget's own cursor, creating (and thereby enabling) an
    # override on first use. Use this to configure the cursor directly, e.g.
    # `widget.cursor!.shape = :line`. Changes only take visible effect while the
    # widget is focused; otherwise they are recorded and applied on focus.
    def cursor! : Cursor
      @cursor ||= Cursor.new
    end

    # Sets this widget's cursor shape (and blink), overriding the screen default
    # while the widget is focused. Routes through the screen so the hardware vs.
    # artificial decision and (re)rendering are identical to the screen cursor.
    def cursor_shape(shape : Tput::CursorShape = Tput::CursorShape::Block, blink : Bool = false)
      screen?.try &.cursor_shape shape, blink, cursor!
    end

    # Sets this widget's cursor color, overriding the screen default while the
    # widget is focused.
    def cursor_color(color : String? = nil)
      screen?.try &.cursor_color color, cursor!
    end

    # Shows this widget's cursor.
    def show_cursor
      screen?.try &.show_cursor cursor!
    end

    # Hides this widget's cursor.
    def hide_cursor
      screen?.try &.hide_cursor cursor!
    end

    # Drops this widget's cursor override, reverting to the screen default. If
    # the widget is focused, the screen default is re-applied right away (and the
    # screen repainted, in case an artificial cursor was being drawn).
    def reset_cursor
      @cursor = nil
      if (s = screen?) && s.focused == self
        s.apply_cursor
        s.render if s.renders > 0
      end
    end
  end
end
