module Crysterm
  # SGR text-attribute booleans shared by `Style` and `Border`.
  module TextAttributes
    # Bold?
    property? bold : Bool = false

    # Italic?
    property? italic : Bool = false

    # Underline?
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
