module Crysterm
  # Terminal (not mouse) cursor state: shape, blink, color and a custom style.
  #
  # A `Window` always has one (`Window#cursor`); a `Widget` may have its own
  # (`Widget#cursor`) to override the window default while focused. Resolved
  # between the two in `Window#active_cursor`.
  #
  # Extends `Tput::Namespace::Cursor` (`shape`, `blink`, `artificial`,
  # `_state`, `_hidden`, ...), adding `style` since Tput has no color property.
  #
  # Lives at namespace level (rather than nested in `Window`) so both
  # `Window` and `Widget` can own one.
  class Cursor < Tput::Namespace::Cursor
    property style : Style = Style.new(fill_char: Config.cursor_glyph)
  end
end
