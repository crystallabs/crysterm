module Crysterm
  # Terminal (not mouse) cursor state: shape, blink, color and a custom style.
  #
  # A `Window` always has one (`Window#cursor`); a `Widget` may have its own
  # (`Widget#cursor`) to override the window default while focused.
  class Cursor < Tput::Namespace::Cursor
    property style : Style = Style.new(fill_char: Config.cursor_glyph)
  end
end
