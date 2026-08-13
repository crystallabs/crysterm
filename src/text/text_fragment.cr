module Crysterm
  # A run of uniformly formatted text within a `TextBlock` (Qt
  # `QTextFragment`). Plain data holder; all invariants (no empty fragments,
  # adjacent same-appearance runs merged) are maintained by the owning block's
  # normalization, so treat instances as block-internal.
  #
  # Positions throughout the framework are codepoint indexes (`String#size`
  # units); grapheme/display width is the rendering layer's concern.
  class TextFragment
    # Setters are protected ("block-internal", per the class doc, enforced):
    # a write from outside the owning block's own normalization desynchronizes
    # the block's text/size/render caches — and with them every later document
    # position. Edit through `TextCursor`/`TextDocument` instead.
    getter text : String
    protected setter text

    # :ditto:
    getter format : TextCharFormat
    protected setter format

    def initialize(@text : String, @format : TextCharFormat = TextCharFormat.default)
    end

    # Length in codepoints.
    def size : Int32
      @text.size
    end
  end

  # Read-only, live view over a block's fragment list — see
  # `TextBlock#fragments` and the sibling `TextBlockView`.
  struct TextFragmentView
    include Indexable(TextFragment)

    def initialize(@array : Array(TextFragment))
    end

    def size : Int32
      @array.size
    end

    @[AlwaysInline]
    def unsafe_fetch(index : Int) : TextFragment
      @array.unsafe_fetch(index)
    end

    # Range/segment indexing, as on `Array` (returns a fresh `Array` — safe to
    # hold, since it is not the storage).
    def [](range : Range) : Array(TextFragment)
      @array[range]
    end

    # :ditto:
    def [](start : Int, count : Int) : Array(TextFragment)
      @array[start, count]
    end
  end
end
