module Crysterm
  # Unicode display-width support for terminal cells.
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
      # Fast path for printable-ASCII content: every char in `0x20..0x7E` is its
      # own width-1 grapheme (no combining marks, wide glyphs, VS16 promotion, or
      # flag pairs), so column width equals bytesize. Skips the `each_grapheme`
      # walk (decode + grapheme-break state machine per char) and the
      # per-grapheme `String` allocation `width(Grapheme)`'s `#to_s` incurs.
      #
      # `ascii_only?` alone is not enough: it is also true for C0 controls
      # (TAB/CR/ESC) and DEL, which `codepoint_width` maps to 0 — the fast path
      # would miscount those, so fall through to the grapheme walk instead.
      # Scanning the raw bytes subsumes the `ascii_only?` check (any byte ≥ 0x80
      # fails the range test) and, unlike a blockless `each_char.all?`,
      # allocates no iterator — this runs per append/wrap while
      # streaming content.
      if string.to_slice.all? { |b| 0x20_u8 <= b <= 0x7E_u8 }
        return string.bytesize
      end
      w = 0
      string.each_grapheme { |g| w += width(g) }
      w
    end

    # Pads *cell* with spaces to *width* display columns under horizontal
    # alignment *align* (`HCenter`/`Right`, else left), returning a new
    # `String`. A cell already at/over *width* is returned unchanged (no
    # clipping) — the shared pad/clip-nothing routine behind the pre-rendered
    # table cells (`TextTable`) and the Markdown table renderer, which maps its
    # `Symbol` alignment onto `Tput::AlignFlag` first. Distinct from the
    # io-based clip-capable `TableLayout#pad_cell_to`.
    def pad(cell : String, width : Int32, align : Tput::AlignFlag?) : String
      pad = width - display_width(cell)
      return cell if pad <= 0
      case align
      when Nil        then cell + (" " * pad)
      when .h_center? then (" " * (pad // 2)) + cell + (" " * (pad - pad // 2))
      when .right?    then (" " * pad) + cell
      else                 cell + (" " * pad)
      end
    end

    # Byte length of the leading run of whole grapheme clusters of *text* that
    # fits in *width* columns (never splitting a grapheme) — i.e. the `end`
    # argument for `text.byte_slice(0, …)` when keeping a text's leading
    # *width* columns. *full_unicode* selects the width metric per grapheme:
    # true measures display columns (wide CJK/emoji count as 2), false counts
    # codepoints (`grapheme.size`), preserving each caller's sizing.
    def leading_byte_len(text : String, cols : Int32, full_unicode : Bool) : Int32
      kept = 0
      end_byte = 0
      text.each_grapheme do |g|
        gw = full_unicode ? width(g) : g.size
        break if kept + gw > cols
        kept += gw
        end_byte += g.bytesize
      end
      end_byte
    end

    # Byte offset at which the trailing run of whole grapheme clusters of *text*
    # that fits in *cols* columns begins (never splitting a grapheme) — i.e. the
    # `start` argument for `text.byte_slice(…)` when keeping a text's trailing
    # *cols* columns. The suffix mirror of `#leading_byte_len`. *full_unicode*
    # selects the width metric per grapheme: true measures display columns (wide
    # CJK/emoji count as 2), false counts codepoints (`grapheme.size`).
    #
    # Computed as "drop as few leading graphemes as needed so the remainder
    # fits": a first pass sums the total width, a second drops leading clusters
    # (advancing the byte offset) until the remainder is within *cols*. This
    # yields exactly the same contiguous longest-fitting suffix a greedy
    # scan-from-the-end would, with no per-grapheme allocation.
    def trailing_byte_len(text : String, cols : Int32, full_unicode : Bool = true) : Int32
      total = 0
      text.each_grapheme { |g| total += full_unicode ? width(g) : g.size }
      return 0 if total <= cols

      start_byte = 0
      remaining = total
      text.each_grapheme do |g|
        break if remaining <= cols
        remaining -= full_unicode ? width(g) : g.size
        start_byte += g.bytesize
      end
      start_byte
    end

    # Whether *c* extends the grapheme cluster it follows: a combining mark, a
    # zero-width joiner (U+200D), a variation selector (U+FE00..U+FE0F), or an
    # emoji skin-tone modifier (U+1F3FB..U+1F3FF). The shared successor test
    # for `Widget#needs_cluster?` / `#extend_grapheme`.
    def grapheme_extender?(c : Char) : Bool
      cp = c.ord
      c.mark? || cp == 0x200D || (0xFE00 <= cp <= 0xFE0F) || (0x1F3FB <= cp <= 0x1F3FF)
    end

    # Whether *c* is a Unicode regional-indicator symbol (U+1F1E6..U+1F1FF); a
    # pair of them forms a flag emoji. `Char` predicate counterpart of the
    # internal codepoint check, shared with the cluster assembly.
    def regional_indicator?(c : Char) : Bool
      regional_indicator? c.ord
    end

    # Display width of a single grapheme cluster (yielded by `each_grapheme`).
    #
    # Reads the stdlib-internal `@cluster` ivar (`Char | String`) directly to
    # avoid the fresh `String` `grapheme.to_s` allocates for the common
    # Char-backed cluster (every CJK ideograph, precomposed accent, narrow
    # glyph). Behavior-identical to `width(grapheme.to_s)`: for a
    # single codepoint no VS16 promotion is possible (a lone codepoint can't
    # carry a following U+FE0F), so the `String` overload's VS16 scan — which
    # only fires for `size > 1` — would be a no-op anyway; a lone regional
    # indicator still renders wide. Multi-codepoint clusters take the `String`
    # branch, preserving VS16/flag handling exactly. Pinned by a spec against
    # the `@cluster` layout (`Char | String`, stable since graphemes landed).
    def width(grapheme : String::Grapheme) : Int32
      case cluster = grapheme.@cluster
      in Char
        return 2 if regional_indicator? cluster.ord
        codepoint_width cluster
      in String
        width cluster
      end
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
      if cp < 0x1100
        # Below the first WIDE range: never wide, so skip that binary search.
        return 0 if char.mark? # combining marks (see NOTE above re: Mc)
        return 0 if zero_width? cp
        return 1
      end
      # `wide?` first: CJK/emoji cells resolve on one binary search instead of
      # paying the `mark?` category search (a miss for them) before it. The only
      # zero-width marks *inside* WIDE blocks are U+302A..302F and U+3099..309A —
      # excluded here so they keep width 0 (order elsewhere doesn't matter:
      # every other mark/zero-width codepoint is outside the WIDE ranges).
      unless (0x302A <= cp <= 0x302F) || (0x3099 <= cp <= 0x309A)
        return 2 if wide? cp
      end
      return 0 if char.mark? # combining marks (see NOTE above re: Mc)
      return 0 if zero_width? cp
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
      {0x231A, 0x231B},   # ⌚⌛ watch / hourglass (emoji)
      {0x2329, 0x232A},   # angle brackets
      {0x23E9, 0x23EC},   # ⏩⏪⏫⏬ fast forward/rewind (emoji)
      {0x23F0, 0x23F0},   # ⏰ alarm clock (emoji)
      {0x23F3, 0x23F3},   # ⏳ hourglass with flowing sand (emoji)
      {0x25FD, 0x25FE},   # ◽◾ medium small squares (emoji)
      {0x2614, 0x2615},   # ☔☕ umbrella with rain / hot beverage (emoji)
      {0x2648, 0x2653},   # ♈..♓ zodiac signs (emoji)
      {0x267F, 0x267F},   # ♿ wheelchair symbol (emoji)
      {0x2693, 0x2693},   # ⚓ anchor (emoji)
      {0x26A1, 0x26A1},   # ⚡ high voltage (emoji)
      {0x26AA, 0x26AB},   # ⚪⚫ medium white/black circle (emoji)
      {0x26BD, 0x26BE},   # ⚽⚾ soccer / baseball (emoji)
      {0x26C4, 0x26C5},   # ⛄⛅ snowman / sun behind cloud (emoji)
      {0x26CE, 0x26CE},   # ⛎ ophiuchus (emoji)
      {0x26D4, 0x26D4},   # ⛔ no entry (emoji)
      {0x26EA, 0x26EA},   # ⛪ church (emoji)
      {0x26F2, 0x26F3},   # ⛲⛳ fountain / flag in hole (emoji)
      {0x26F5, 0x26F5},   # ⛵ sailboat (emoji)
      {0x26FA, 0x26FA},   # ⛺ tent (emoji)
      {0x26FD, 0x26FD},   # ⛽ fuel pump (emoji)
      {0x2705, 0x2705},   # ✅ white heavy check mark (emoji)
      {0x270A, 0x270B},   # ✊✋ raised fist / hand (emoji)
      {0x2728, 0x2728},   # ✨ sparkles (emoji)
      {0x274C, 0x274C},   # ❌ cross mark (emoji)
      {0x274E, 0x274E},   # ❎ negative squared cross mark (emoji)
      {0x2753, 0x2755},   # ❓❔❕ question / exclamation marks (emoji)
      {0x2757, 0x2757},   # ❗ heavy exclamation mark (emoji)
      {0x2795, 0x2797},   # ➕➖➗ heavy plus/minus/division (emoji)
      {0x27B0, 0x27B0},   # ➰ curly loop (emoji)
      {0x27BF, 0x27BF},   # ➿ double curly loop (emoji)
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
