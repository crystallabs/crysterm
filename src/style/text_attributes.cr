module Crysterm
  # SGR text-attribute booleans shared by `Style` and `Border`. `Border` needs
  # its own copies (rather than delegating to a `Style`) so `sattr()` (see
  # `widget_rendering.cr`) can work directly on a `Border` object.
  module TextAttributes
    # Bold?
    property? bold : Bool = false

    # Italic?
    property? italic : Bool = false

    # Unedline?
    property? underline : Bool = false

    # Blink?
    property? blink : Bool = false

    # Reverse video?
    property? reverse : Bool = false

    # Strikethrough?
    property? strike : Bool = false

    # Visible?
    property? visible : Bool = true
  end
end
