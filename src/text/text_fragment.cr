module Crysterm
  # A run of uniformly formatted text within a `TextBlock` (Qt
  # `QTextFragment`). Plain data holder; all invariants (no empty fragments,
  # adjacent same-appearance runs merged) are maintained by the owning block's
  # normalization, so treat instances as block-internal.
  #
  # Positions throughout the framework are codepoint indexes (`String#size`
  # units); grapheme/display width is the rendering layer's concern.
  class TextFragment
    property text : String
    property format : TextCharFormat

    def initialize(@text : String, @format : TextCharFormat = TextCharFormat.default)
    end

    # Length in codepoints.
    def size : Int32
      @text.size
    end
  end
end
