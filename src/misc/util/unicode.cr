module Crysterm
  # Unicode display-width support for terminal cells (Phase 0 of grapheme
  # support).
  #
  # Terminal layout is measured in **columns**, not codepoints: a combining mark
  # occupies 0 columns, an East-Asian-Wide / emoji glyph occupies 2, everything
  # else 1. This module answers "how many columns does this text occupy",
  # operating on **grapheme clusters** (via Crystal's UAX-#29
  # `String#each_grapheme`) so a user-perceived character is measured as a
  # single unit.
  #
  # Width rules follow the common `wcwidth` + East-Asian-Width convention plus
  # emoji. Terminals disagree on a few cases (ambiguous-width chars, ZWJ emoji,
  # flags); treat the values here as authoritative.
  #
  # NOTE (known approximation): zero-width detection uses `Char#mark?`, which
  # also matches spacing combining marks (general category Mc). True `wcwidth`
  # only zero-widths Mn/Me. This is rare in TUI content and can be refined later
  # by excluding Mc ranges.
  module Unicode
    extend self

    # Matches astral (> U+FFFF) characters. Used by the non-full-unicode
    # fallback (`Helpers#drop_unicode`) to replace what a narrow terminal cannot
    # render.
    AllRegex = /[\x{10000}-\x{10FFFF}]/

    # Display width, in terminal columns, of a whole string: the sum of the
    # widths of its grapheme clusters.
    def display_width(string : String) : Int32
      # Fast path for ASCII-only content: every ASCII codepoint is its own
      # width-1 grapheme (no combining marks, wide glyphs, VS16 promotion, or
      # flag pairs), so column width equals bytesize. Skips the `each_grapheme`
      # walk (decode + grapheme-break state machine per char) and the
      # per-grapheme `String` allocation `width(Grapheme)`'s `#to_s` incurs.
      return string.bytesize if string.ascii_only?
      w = 0
      string.each_grapheme { |g| w += width(g) }
      w
    end

    # Display width of a single grapheme cluster (yielded by `each_grapheme`).
    def width(grapheme : String::Grapheme) : Int32
      width grapheme.to_s
    end

    # Display width of a single grapheme cluster given as a `String`.
    #
    # The width is driven by the cluster's base codepoint; trailing combining
    # marks / joiners / variation selectors add nothing. Two cluster shapes are
    # special-cased to 2 columns: regional-indicator flags, and emoji whose
    # presentation is forced wide by a VS16 (U+FE0F) selector.
    def width(grapheme : String) : Int32
      return 0 if grapheme.empty?

      first = grapheme[0]
      # A flag is a cluster of regional indicators; renders in 2 columns.
      return 2 if regional_indicator? first.ord

      w = codepoint_width first
      # VS16 promotes a narrow base to a wide glyph; it can only occur in a
      # multi-codepoint cluster, so single-codepoint graphemes skip the scan.
      if w < 2 && grapheme.size > 1 && grapheme.includes? '\u{FE0F}'
        w = 2
      end
      w
    end

    # Display width of a single codepoint, ignoring clustering. Prefer the
    # grapheme-aware `#width` for user text; this is the low-level building block.
    def width(char : Char) : Int32
      codepoint_width char
    end

    # Columns occupied by a single codepoint: 0 (control / combining /
    # zero-width), 2 (East-Asian-Wide / emoji), or 1 (everything else).
    def codepoint_width(char : Char) : Int32
      cp = char.ord
      # Fast path for printable ASCII: always 1 column, so skip the `mark?`
      # category lookup and the `wide?` binary search below.
      return 1 if 0x20 <= cp <= 0x7E
      return 0 if cp == 0
      return 0 if char.control?
      return 0 if char.mark? # combining marks (see NOTE above re: Mc)
      return 0 if zero_width? cp
      return 2 if wide? cp
      1
    end

    private def zero_width?(cp : Int32) : Bool
      cp == 0x200B ||               # zero width space
        cp == 0x200C ||             # zero width non-joiner
        cp == 0x200D ||             # zero width joiner
        cp == 0xFEFF ||             # zero width no-break space / BOM
        (0x1160 <= cp <= 0x11FF) || # Hangul Jungseong/Jongseong (conjoining)
        (0xFE00 <= cp <= 0xFE0F) || # variation selectors
        (0xE0100 <= cp <= 0xE01EF)  # variation selectors supplement
    end

    private def regional_indicator?(cp : Int32) : Bool
      0x1F1E6 <= cp <= 0x1F1FF
    end

    private def wide?(cp : Int32) : Bool
      lo = 0
      hi = WIDE.size - 1
      while lo <= hi
        mid = (lo + hi) // 2
        r = WIDE.unsafe_fetch mid
        if cp < r[0]
          hi = mid - 1
        elsif cp > r[1]
          lo = mid + 1
        else
          return true
        end
      end
      false
    end

    # Sorted, non-overlapping ranges of East-Asian-Wide / Fullwidth codepoints
    # plus emoji that render in 2 columns. Derived from the standard
    # `wcwidth`/East-Asian-Width data.
    WIDE = [
      {0x1100, 0x115F},   # Hangul Jamo (leading consonants)
      {0x2329, 0x232A},   # angle brackets
      {0x2B1B, 0x2B1C},   # ⬛⬜ black/white large square (emoji)
      {0x2B50, 0x2B50},   # ⭐ white medium star (emoji)
      {0x2B55, 0x2B55},   # ⭕ heavy large circle (emoji)
      {0x2E80, 0x303E},   # CJK radicals .. Kangxi .. CJK symbols
      {0x3041, 0x33FF},   # Hiragana, Katakana, CJK symbols/letters
      {0x3400, 0x4DBF},   # CJK Unified Ideographs Extension A
      {0x4E00, 0x9FFF},   # CJK Unified Ideographs
      {0xA000, 0xA4CF},   # Yi
      {0xA960, 0xA97F},   # Hangul Jamo Extended-A
      {0xAC00, 0xD7A3},   # Hangul Syllables
      {0xF900, 0xFAFF},   # CJK Compatibility Ideographs
      {0xFE10, 0xFE19},   # vertical forms
      {0xFE30, 0xFE6F},   # CJK compatibility / small forms
      {0xFF00, 0xFF60},   # Fullwidth forms
      {0xFFE0, 0xFFE6},   # Fullwidth signs
      {0x1B000, 0x1B16F}, # Kana supplement / extended
      {0x1F004, 0x1F004}, # mahjong red dragon
      {0x1F0CF, 0x1F0CF}, # playing card black joker
      {0x1F18E, 0x1F18E}, # negative squared AB
      {0x1F191, 0x1F19A}, # squared CL .. VS
      {0x1F200, 0x1F2FF}, # enclosed ideographic supplement
      {0x1F300, 0x1F64F}, # misc symbols & pictographs, emoticons
      {0x1F680, 0x1F6FF}, # transport & map symbols
      {0x1F7E0, 0x1F7EB}, # geometric shapes extended (🟠🟢🟥🟫 colored circles/squares)
      {0x1F7F0, 0x1F7F0}, # 🟰 heavy equals sign
      {0x1F900, 0x1F9FF}, # supplemental symbols & pictographs
      {0x1FA70, 0x1FAFF}, # symbols & pictographs extended-A
      {0x20000, 0x3FFFD}, # CJK Unified Ideographs Extension B..
    ]
  end
end
