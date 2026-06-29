module Crysterm
  # Terminal (not mouse) cursor state: shape, blink, color and a custom style.
  #
  # A `Cursor` describes how the terminal cursor should look. A `Window` always
  # has one — its default (`Window#cursor`) — and any `Widget` may optionally
  # have its own (`Widget#cursor`) to override the window default while it is
  # focused. The resolution between the two happens in `Window#active_cursor`.
  #
  # Extends `Tput::Namespace::Cursor` (which provides `shape`, `blink`,
  # `artificial`, `_state`, `_hidden`, ...) and adds `style`, because the Tput
  # class has no property for color.
  #
  # This class used to be nested as `Window::Cursor`; it was lifted to the
  # namespace level so both `Window` and `Widget` can own one (see the TODO that
  # previously lived in `window_cursor.cr`).
  class Cursor < Tput::Namespace::Cursor
    property style : Style = Style.new(fill_char: Config.cursor_glyph)
  end
end
