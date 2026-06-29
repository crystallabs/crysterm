module Crysterm
  # A self-contained VT100/xterm-subset terminal emulator.
  #
  # SUPPORTING CODE — like `Pty`, this has no dependency on the widget tree and
  # is a candidate for extraction into its own shard. It is the Crystal-side
  # counterpart of the `term.js` library that blessed's `terminal` widget drove:
  # it consumes the raw byte stream a child program writes to a PTY and maintains
  # an in-memory grid of cells (attribute + character) that a renderer can copy
  # onto the window.
  #
  # Scope: it implements the sequences a normal interactive shell and the common
  # full-window programs (vim, htop, less, top, man) rely on — cursor movement,
  # SGR colours/styles, erase/insert/delete, scroll regions and scrollback,
  # cursor save/restore, title (OSC 0/2), the basic device-status/attributes
  # replies, the alternate window buffer (DECSET 47/1047/1049), the DEC
  # special-graphics (line-drawing) charset (`ESC ( 0`), and mouse-mode tracking
  # (the active mode is exposed for the widget to encode and forward reports). It
  # intentionally does NOT implement double-width/height lines or G2/G3 charset
  # invocation; those are noted at each site and easy to add later without
  # changing the public surface.
  #
  # The SGR ('m') handler deliberately reuses `Crysterm::Screen.attr2code`, the
  # same well-tested converter the rest of Crysterm uses, so 16/256/truecolour
  # all behave identically to native content.
  class TerminalEmulator
    # One grid cell. A `struct` so an `Array(Cell)` stores its cells inline in one
    # contiguous buffer instead of as `@cols` separate heap objects per line —
    # which dominated allocation on the hot scroll path (every scrolled line
    # allocated a fresh `blank_line`). Because a struct read from `arr[x]` is a
    # *copy*, cells are never mutated through the index (`arr[x].attr = …` would
    # update the copy and be lost); writers replace the whole cell instead
    # (`arr[x] = Cell.new(…)`). All such writers live in this file.
    struct Cell
      property attr : Int64
      property char : Char

      def initialize(@attr : Int64, @char : Char)
      end
    end

    # Maximum number of scrolled-off lines retained for scrollback.
    SCROLLBACK_LIMIT = 1000

    getter cols : Int32
    getter rows : Int32

    # Cursor position within the *viewport* (0-based; `x` may momentarily equal
    # `cols` as a deferred-wrap pending state, surfaced via `#cursor_x`).
    getter x : Int32 = 0
    getter y : Int32 = 0

    # All lines, scrollback first; the live window is the `rows` lines starting
    # at `#ybase`. `#ydisp` is the top line currently *displayed* (equal to
    # `ybase` unless the user has scrolled back).
    getter lines : Array(Array(Cell))
    getter ybase : Int32 = 0
    getter ydisp : Int32 = 0

    getter? cursor_hidden : Bool = false

    # Optional sink for replies the child solicits (DSR/DA) — wire this to the
    # PTY's input so e.g. cursor-position reports get answered.
    property output : IO? = nil

    # Optional notifications.
    property on_bell : Proc(Nil)? = nil
    property on_title : Proc(String, Nil)? = nil
    # Called after each `#feed` so the owner can request a window render.
    property on_refresh : Proc(Nil)? = nil

    @default_attr : Int64
    @cur_attr : Int64

    @scroll_top : Int32 = 0
    @scroll_bottom : Int32 = 0

    @saved_x : Int32 = 0
    @saved_y : Int32 = 0
    @saved_attr : Int64
    # DECSC (`ESC 7`) saves more than the cursor position and SGR attributes: per
    # the DEC spec it also snapshots the charset designations (G0/G1 special),
    # the active GL invocation (SI/SO), origin mode (DECOM) and autowrap (DECAWM),
    # all restored by DECRC (`ESC 8`). Without these a child that draws with the
    # line-drawing set inside a DECSC/DECRC pair — `ESC ( 0` … `ESC 7` … switch
    # charset … `ESC 8` — saw its charset left switched after the restore, so the
    # text it expected as line-drawing glyphs rendered as plain ASCII.
    @saved_g0_special = false
    @saved_g1_special = false
    @saved_gl = 0
    @saved_origin_mode = false
    @saved_autowrap = true

    # Deferred wrap: after writing the last column we stay on it until the next
    # printable char, matching xterm (prevents a spurious blank line when text
    # exactly fills a row).
    @wrap_pending : Bool = false

    # Autowrap mode (DECAWM, DECSET ?7): when on (the xterm/terminfo `am` default),
    # a glyph written past the last column wraps to the next line. When a child
    # turns it off (`CSI ? 7 l`), the cursor instead *sticks* at the last column
    # and each further glyph overwrites it — the standard way to paint the
    # bottom-right cell (or a full-width status line) without triggering a scroll.
    # Without this the emulator wrapped unconditionally, so such a child saw its
    # last column scroll the window and its rightmost glyph land on the next line.
    @autowrap = true

    # Insert/replace mode (IRM, the ANSI — *non*-private — mode 4, `CSI 4 h` /
    # `CSI 4 l`; terminfo `smir`/`rmir`). When on, a printed glyph is *inserted*
    # at the cursor — the rest of the line shifts right and the overflow drops off
    # the end — instead of overwriting in place. A child that edits a line with
    # the insert-character capabilities (rather than `CSI @`) relies on this;
    # without it each typed character clobbered the one already under the cursor.
    @insert_mode = false

    # The last graphic character actually placed in the grid (after charset
    # translation), so REP (`CSI Pn b`) can repeat it. ncurses emits REP on a
    # terminal whose terminfo advertises `rep` (xterm-256color does:
    # `rep=\E[%p1%db`) to draw a run of one glyph — e.g. a horizontal rule — in a
    # few bytes; without REP the run collapses to a single glyph on window.
    @last_char : Char? = nil

    # Parser state. The CSI/OSC accumulation buffers are reused `IO::Memory`s
    # (cleared, not reallocated, at the start of each sequence): a child redrawing
    # a full window emits a CSI per cursor move / colour change, and the old
    # per-byte `@csi_buf += c` allocated a fresh `String` on every appended byte.
    # `IO::Memory` also makes long OSC payloads (e.g. an OSC 52 clipboard set)
    # linear instead of the quadratic copying that repeated `String` concat did.
    @state : Symbol = :ground
    @csi_buf = IO::Memory.new
    @csi_private : Bool = false
    # Leading private/intermediate prefix byte of the current CSI (`<`, `=`, `>`
    # or `?`, range 0x3c-0x3f), or nil for a plain CSI. Kept out of `@csi_buf` so
    # parameter parsing stays numeric, and so `c`/`n` finals can tell a secondary
    # DA (`CSI > c`) or DEC-private DSR (`CSI ? 6 n`) from their plain forms.
    @csi_prefix : Char? = nil
    @osc_buf = IO::Memory.new
    @osc_esc : Bool = false
    # True while the accumulated string is a DCS/SOS/PM/APC payload (entered via
    # `ESC P`/`X`/`^`/`_`) rather than a real OSC (`ESC ]`). Such a string is
    # swallowed up to its terminator but must NOT be parsed as a window title —
    # otherwise e.g. a child's sixel `ESC P 0;1;0 q …` (which begins `0;…`) would
    # be mistaken for an OSC 0 title set.
    @osc_string : Bool = false

    # Trailing incomplete UTF-8 bytes held back between `#feed` calls.
    @leftover : Bytes = Bytes.empty

    # Charset state. G0/G1 can each be designated the DEC special-graphics
    # (line-drawing) set via `ESC ( 0` / `ESC ) 0`; `@gl` selects which is active
    # (SI→G0, SO→G1). When the active set is special, printable bytes 0x60–0x7e
    # are translated through `DEC_GRAPHICS`.
    @g0_special = false
    @g1_special = false
    @gl = 0
    @charset_index = 0 # which G is being designated while in :charset state

    # Horizontal tab stops, as the set of columns HT/CHT advance *to* (and CBT
    # backs up to). Defaults to every 8th column; a child can add a stop at the
    # cursor with HTS (`ESC H`) and clear stops with TBC (`CSI g`). Honouring
    # these is what lets a program that programmatically sets its own stops (e.g.
    # for table columns, via `tput hts`) tab to them instead of a hardcoded 8.
    @tab_stops = Set(Int32).new

    # Alternate-window state (DECSET 47/1047/1049). When active, `@lines` is a
    # fresh page and the main buffer is parked in `@main_*` until restored.
    getter? alt_active : Bool = false
    @main_lines : Array(Array(Cell))? = nil
    @main_ybase = 0
    @main_ydisp = 0
    @main_scroll_top = 0
    @main_scroll_bottom = 0
    @alt_saved_x = 0
    @alt_saved_y = 0
    @alt_saved_attr : Int64

    # Mouse tracking requested by the child. `@mouse_tracking` is the active
    # DECSET tracking mode (0 = off, else 9/1000/1002/1003); `@mouse_encoding`
    # is how reports are framed (`:normal`, `:sgr`, `:utf8`, `:urxvt`). The
    # widget reads these to decide whether/how to forward `Event::Mouse`.
    getter mouse_tracking : Int32 = 0
    getter mouse_encoding : Symbol = :normal

    # Origin mode (DECOM, DECSET ?6): when on, row addressing (CUP/VPA) is
    # relative to the scroll region's top and the cursor cannot leave it.
    @origin_mode = false

    # Bracketed-paste (?2004) and focus-reporting (?1004) modes the child asked
    # for. The emulator only tracks them; the widget acts on them (wrapping
    # pasted input / emitting focus reports).
    getter? bracketed_paste : Bool = false
    getter? focus_reporting : Bool = false

    # Sentinel char marking the trailing half of a wide (2-column) glyph in the
    # emulator grid. Matches `Window::Cell::CONTINUATION` so the widget can copy
    # the notion straight through to the window's own continuation cells.
    CONTINUATION = '\u0000' # NUL — same sentinel as Window::Cell::CONTINUATION

    # VT100 DEC special-graphics map: the line-drawing glyphs a child selects via
    # `ESC ( 0`. Only 0x60–0x7e differ from ASCII; everything else passes through.
    DEC_GRAPHICS = {
      '`' => '◆', 'a' => '▒', 'b' => '␉', 'c' => '␌', 'd' => '␍', 'e' => '␊',
      'f' => '°', 'g' => '±', 'h' => '␤', 'i' => '␋', 'j' => '┘', 'k' => '┐',
      'l' => '┌', 'm' => '└', 'n' => '┼', 'o' => '⎺', 'p' => '⎻', 'q' => '─',
      'r' => '⎼', 's' => '⎽', 't' => '├', 'u' => '┤', 'v' => '┴', 'w' => '┬',
      'x' => '│', 'y' => '≤', 'z' => '≥', '{' => 'π', '|' => '≠', '}' => '£',
      '~' => '·',
    }

    def initialize(@cols : Int32, @rows : Int32, default_attr : Int64)
      @cols = 1 if @cols < 1
      @rows = 1 if @rows < 1
      @default_attr = default_attr
      @cur_attr = default_attr
      @saved_attr = default_attr
      @alt_saved_attr = default_attr
      @scroll_bottom = @rows - 1
      @lines = blank_page
      reset_tab_stops
    end

    # Resets the horizontal tab stops to the default — one every 8 columns — for
    # the current width. Used at construction, on RIS, and on resize.
    private def reset_tab_stops : Nil
      @tab_stops.clear
      i = 8
      while i < @cols
        @tab_stops << i
        i += 8
      end
    end

    # Updates the attribute used for cleared/empty cells (the widget's resolved
    # default style). Existing content is untouched.
    def default_attr=(attr : Int64) : Nil
      @default_attr = attr
    end

    # Attribute used to fill erased / freshly scrolled cells: default flags and
    # foreground, but the *current* background (background-colour erase, BCE).
    private def erase_attr : Int64
      Attr.pack(Attr.flags(@default_attr), Attr.fg(@default_attr), Attr.bg(@cur_attr))
    end

    private def blank_line : Array(Cell)
      ea = erase_attr
      Array(Cell).new(@cols) { Cell.new(ea, ' ') }
    end

    # A fresh page of `@rows` blank lines at the current width/erase attr. The
    # initial grid, the alternate page (`#enter_alt`) and a full reset
    # (`#full_reset`) all build their `@lines` this way.
    private def blank_page : Array(Array(Cell))
      page = Array(Array(Cell)).new
      @rows.times { page << blank_line }
      page
    end

    # Overwrites every cell of an existing line with the current erase blank,
    # reusing the line's storage (used to recycle a scrolled-off line into a fresh
    # blank one without allocating). Re-fits the line to `@cols` in the unusual
    # case its length drifted from the current width (e.g. a mid-stream resize).
    private def blank_in_place(line : Array(Cell)) : Nil
      blank = Cell.new(erase_attr, ' ')
      if line.size == @cols
        line.fill blank
      else
        line.clear
        @cols.times { line << blank }
      end
    end

    # Recycles the top line's `Array(Cell)` storage as a fresh blank bottom row
    # (`shift` it off, blank it in place, `push` it back) instead of allocating a
    # new `blank_line` and letting the displaced top become garbage. Used on the
    # two full-window `#scroll_up` paths that discard the top line — the alt page
    # (no scrollback) and a full scrollback buffer — so neither allocates per
    # scrolled line.
    private def recycle_top_row : Nil
      recycled = @lines.shift
      blank_in_place recycled
      @lines << recycled
    end

    # The live (cursor) line.
    private def cur_line : Array(Cell)
      @lines[@ybase + @y]
    end

    # ───────────────────────── input ─────────────────────────

    # Feeds raw bytes from the child. Re-assembles UTF-8 across calls so a
    # multibyte character split over two reads is not corrupted.
    def feed(bytes : Bytes) : Nil
      unless @leftover.empty?
        joined = Bytes.new(@leftover.size + bytes.size)
        @leftover.copy_to joined
        bytes.copy_to(joined + @leftover.size)
        bytes = joined
        @leftover = Bytes.empty
      end

      complete, @leftover = split_incomplete_utf8 bytes

      # All control/escape bytes are ASCII, so decoding the complete prefix as a
      # String is safe for the parser; only printable multibyte glyphs were ever
      # at risk, and those are now whole.
      #
      # Fast path: terminal output is overwhelmingly ASCII, so feed those bytes
      # straight as chars without materializing a `String` (which copied the whole
      # chunk on every read). The moment a multibyte lead byte (>= 0x80) appears,
      # decode the *remainder* via `String` exactly as before — same UTF-8 and
      # invalid-byte handling — preserving behaviour while skipping the per-feed
      # allocation + copy for the common all-ASCII case.
      ptr = complete.to_unsafe
      n = complete.size
      i = 0
      while i < n
        b = ptr[i]
        if b < 0x80
          handle_char b.unsafe_chr
          i += 1
        else
          String.new(complete[i, n - i]).each_char { |c| handle_char c }
          break
        end
      end

      @on_refresh.try &.call
    end

    def feed(data : String) : Nil
      feed data.to_slice
    end

    # Splits off any trailing bytes that form an *incomplete* UTF-8 sequence so
    # they can be prepended to the next chunk. Returns {complete, leftover}.
    private def split_incomplete_utf8(bytes : Bytes) : {Bytes, Bytes}
      n = bytes.size
      k = 1
      while k <= 3 && k <= n
        b = bytes[n - k]
        if b >= 0x80 && b < 0xC0
          k += 1 # continuation byte: keep walking back toward the lead byte
          next
        elsif b >= 0xC0
          need = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : 2)
          return {bytes[0, n - k], bytes[n - k, k]} if k < need
          return {bytes, Bytes.empty}
        else
          return {bytes, Bytes.empty} # ASCII byte: everything up to here is whole
        end
      end
      {bytes, Bytes.empty}
    end

    private def handle_char(c : Char) : Nil
      # An ESC (0x1b) arriving in the middle of an escape/CSI/charset sequence
      # aborts whatever was in progress and begins a *new* escape — the VT500
      # parser's "anywhere: ESC → clear + enter escape" transition. Without this,
      # an ESC seen mid-CSI fell through to `dispatch_csi` (a no-op for a non-final
      # byte) which dropped us to `:ground`, so the following `[` of the new
      # sequence (e.g. an interrupted/re-issued `CSI … ESC [ … H`) leaked into the
      # grid as literal text instead of being parsed. The `:osc` (string) state is
      # excluded: it does its own ESC handling for the `ESC \` (ST) terminator.
      if c.ord == 0x1b && (@state == :esc || @state == :csi || @state == :charset)
        @state = :esc
        return
      end
      case @state
      when :ground  then handle_ground c
      when :esc     then handle_esc c
      when :csi     then handle_csi c
      when :osc     then handle_osc c
      when :charset then handle_charset c
      end
    end

    # Designates the pending G-set (`@charset_index`) as special-graphics when
    # the byte is '0', else as a normal (ASCII-ish) set. Only G0/G1 affect
    # rendering; G2/G3 are tracked-but-unused (rarely invoked as GL).
    private def handle_charset(c : Char) : Nil
      special = c == '0'
      case @charset_index
      when 0 then @g0_special = special
      when 1 then @g1_special = special
      end
      @state = :ground
    end

    private def handle_ground(c : Char) : Nil
      case c.ord
      when 0x1b             then @state = :esc
      when 0x07             then @on_bell.try &.call
      when 0x08             then backspace
      when 0x09             then tab
      when 0x0a, 0x0b, 0x0c then line_feed
      when 0x0d             then @x = 0; @wrap_pending = false
      when 0x0e             then @gl = 1 # SO: invoke G1 into GL
      when 0x0f             then @gl = 0 # SI: invoke G0 into GL
      else
        # 0x7f (DEL) is a fill/padding control, not a glyph: VT100/xterm discard
        # it from the data stream. Without this guard it falls through here (it is
        # `>= 0x20`) and gets written into the grid as a spurious cell. Bytes in
        # 0x00-0x1f that aren't handled above are already dropped by the `>= 0x20`
        # test; only DEL needs excluding (0x80+ are printable multibyte glyphs).
        print_char c if c.ord >= 0x20 && c.ord != 0x7f
      end
    end

    private def handle_esc(c : Char) : Nil
      case c
      when '['
        @state = :csi
        @csi_buf.clear
        @csi_private = false
        @csi_prefix = nil
      when ']'
        @state = :osc
        @osc_buf.clear
        @osc_esc = false
        @osc_string = false
      when '(', ')', '*', '+'
        @charset_index = {'(' => 0, ')' => 1, '*' => 2, '+' => 3}[c]
        @state = :charset
      when '#', ' ', '%'
        # 3-byte intermediate escapes whose final byte must be swallowed, not
        # printed: `ESC # n` (DECALN / double-width/height line — line size is
        # not implemented, but the digit must not leak as text), `ESC SP F/G/…`
        # (S7C1T/S8C1T, ANSI conformance) and `ESC % @/G` (charset selection;
        # we are always UTF-8). Route through the charset state with a designate-
        # nothing index (-1) so the next byte is consumed with no side effect.
        @charset_index = -1
        @state = :charset
      when 'P', 'X', '^', '_'
        # DCS/SOS/PM/APC string — swallow like an OSC (until ST/BEL), but flag it
        # so the payload is discarded rather than parsed as an OSC title.
        @state = :osc
        @osc_buf.clear
        @osc_esc = false
        @osc_string = true
      when '7' then save_cursor; @state = :ground
      when '8' then restore_cursor; @state = :ground
      when 'H' then @tab_stops << cursor_x; @state = :ground # HTS: set tab stop at cursor
      when 'M' then reverse_index; @state = :ground          # RI
      when 'D' then line_feed; @state = :ground              # IND
      when 'E' then @x = 0; line_feed; @state = :ground      # NEL
      when 'c' then full_reset; @state = :ground             # RIS
      else
        @state = :ground # '=', '>', and anything else: no-op
      end
    end

    private def handle_osc(c : Char) : Nil
      if @osc_esc
        @osc_esc = false
        if c == '\\' # ST = ESC \
          finish_osc
          @state = :ground
          return
        end
      end
      case c.ord
      when 0x07 then finish_osc; @state = :ground # BEL terminator
      when 0x1b then @osc_esc = true
      else           @osc_buf << c
      end
    end

    private def finish_osc : Nil
      # A DCS/SOS/PM/APC string was only swallowed for its terminator; never
      # interpret its payload as an OSC title.
      return if @osc_string
      # Only window/icon title (codes 0, 1, 2) are acted on. The buffer is
      # materialized once here (on the rare terminator), not per appended byte.
      buf = @osc_buf.to_s
      if idx = buf.index(';')
        code = buf[0, idx]
        text = buf[(idx + 1)..]
        @on_title.try(&.call(text)) if code == "0" || code == "1" || code == "2"
      end
    end

    private def handle_csi(c : Char) : Nil
      o = c.ord
      # A leading byte in 0x3c-0x3f (`<` `=` `>` `?`) is the private/intermediate
      # prefix — capture it instead of folding it into the numeric parameters.
      if @csi_prefix.nil? && @csi_buf.empty? && 0x3c <= o <= 0x3f
        @csi_prefix = c
        @csi_private = (c == '?')
        return
      end
      if o >= 0x20 && o <= 0x3f
        @csi_buf.write_byte(o.to_u8) # parameter / intermediate bytes (all ASCII)
        return
      end
      dispatch_csi c # final byte (0x40..0x7e)
      @state = :ground
    end

    # ───────────────────────── CSI dispatch ─────────────────────────

    # Largest accumulator value that can still take another decimal digit without
    # overflowing `Int32`. The hand-rolled param parsers below accumulate digits
    # with `val * 10 + d`, which — unlike the `String#to_i?` the old `split`-based
    # parser used (it returns `nil`, not raises, on overflow) — would raise
    # `OverflowError` on an adversarial CSI carrying a huge number (e.g.
    # `CSI 9999999999 H`), tearing down the whole session in the reader fiber. A
    # field that would overflow is instead flagged `bad`, so it reads as 0 — the
    # exact value the old `s.to_i? || 0` produced for an out-of-range field.
    PARAM_ACCUM_MAX = (Int32::MAX - 9) // 10

    # The n-th `;`-separated parameter in `@csi_buf` (0-based), parsed in place,
    # or nil when there is no n-th field. An empty or non-numeric field reads as
    # 0, matching the old `split(';').map { |s| s.to_i? || 0 }`. No allocation —
    # this replaces the per-CSI `Array(String)` + `Array(Int32)` that `split`/
    # `map` produced on every cursor move / SGR change a full-window child emits.
    private def csi_param_raw(n : Int32) : Int32?
      ptr = @csi_buf.buffer
      size = @csi_buf.bytesize
      field = 0
      val = 0
      bad = false # field holds a non-digit ⇒ `to_i?` would have failed ⇒ 0
      idx = 0
      while idx < size
        b = ptr[idx].to_i
        if b == ';'.ord
          return (bad ? 0 : val) if field == n
          field += 1
          val = 0
          bad = false
        elsif '0'.ord <= b <= '9'.ord
          if val > PARAM_ACCUM_MAX
            bad = true # one more digit would overflow Int32 ⇒ field reads as 0
          else
            val = val * 10 + (b - '0'.ord)
          end
        else
          bad = true
        end
        idx += 1
      end
      return (bad ? 0 : val) if field == n
      nil
    end

    # The n-th parameter, falling back to `default` when it is absent or zero
    # (the VT "missing/zero ⇒ default" rule). Mirrors the old `param`.
    private def param(n : Int32, default : Int32) : Int32
      v = csi_param_raw n
      (v.nil? || v == 0) ? default : v
    end

    # The n-th parameter as a raw code (absent ⇒ 0), for the handlers that want
    # the literal value rather than the missing-⇒-default rule (`J`/`K`/`n`/`c`).
    private def param0(n : Int32) : Int32
      csi_param_raw(n) || 0
    end

    # Yields every `;`-separated parameter in turn (used by `set_mode`). Like the
    # old `split(';')`, always yields at least one value (0 for an empty buffer).
    private def each_csi_param(& : Int32 ->) : Nil
      ptr = @csi_buf.buffer
      size = @csi_buf.bytesize
      val = 0
      bad = false
      idx = 0
      while idx < size
        b = ptr[idx].to_i
        if b == ';'.ord
          yield(bad ? 0 : val)
          val = 0
          bad = false
        elsif '0'.ord <= b <= '9'.ord
          if val > PARAM_ACCUM_MAX
            bad = true # one more digit would overflow Int32 ⇒ field reads as 0
          else
            val = val * 10 + (b - '0'.ord)
          end
        else
          bad = true
        end
        idx += 1
      end
      yield(bad ? 0 : val)
    end

    # CUU/CPL: move the cursor up *n* rows, stopping at the scroll region's top
    # margin when the cursor starts at or below it (matching xterm's `CursorUp`),
    # else at the top of the window. Without the margin clamp, a child that drives
    # a scroll-region status area with CUU could walk the cursor up out of its
    # region and overwrite rows above it.
    private def cursor_up(n : Int32) : Nil
      lo = @y >= @scroll_top ? @scroll_top : 0
      @y = Math.max(lo, @y - n)
    end

    # CUD/CNL: move the cursor down *n* rows, stopping at the scroll region's
    # bottom margin when the cursor starts at or above it (xterm's `CursorDown`),
    # else at the bottom of the window. The mirror of `#cursor_up`.
    private def cursor_down(n : Int32) : Nil
      hi = @y <= @scroll_bottom ? @scroll_bottom : @rows - 1
      @y = Math.min(hi, @y + n)
    end

    # Moves the cursor to a 0-based row, honouring origin mode: when set, the row
    # is relative to the scroll region's top and clamped inside the region.
    private def set_row(row : Int32) : Nil
      @y = if @origin_mode
             clamp(@scroll_top + row, @scroll_top, @scroll_bottom)
           else
             clamp(row, 0, @rows - 1)
           end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def dispatch_csi(c : Char) : Nil
      case c
      when 'A'      then cursor_up(param(0, 1)); @wrap_pending = false
      when 'B'      then cursor_down(param(0, 1)); @wrap_pending = false
      when 'C'      then @x = Math.min(@cols - 1, @x + param(0, 1)); @wrap_pending = false
      when 'D'      then @x = Math.max(0, @x - param(0, 1)); @wrap_pending = false
      when 'E'      then @x = 0; cursor_down(param(0, 1)); @wrap_pending = false
      when 'F'      then @x = 0; cursor_up(param(0, 1)); @wrap_pending = false
      when 'G', '`' then @x = clamp(param(0, 1) - 1, 0, @cols - 1); @wrap_pending = false
      when 'd'      then set_row(param(0, 1) - 1); @wrap_pending = false
      when 'H', 'f'
        set_row(param(0, 1) - 1)
        @x = clamp(param(1, 1) - 1, 0, @cols - 1)
        @wrap_pending = false
      when 'J' then erase_display(param0(0))
      when 'K' then erase_line(param0(0))
      when 'L' then insert_lines(param(0, 1))
      when 'M' then delete_lines(param(0, 1))
      when 'P' then delete_chars(param(0, 1))
      when '@' then insert_chars(param(0, 1))
      when 'X' then erase_chars(param(0, 1))
      when 'S' then scroll_region_times(param(0, 1)) { scroll_up }   # SU
      when 'T' then scroll_region_times(param(0, 1)) { scroll_down } # SD
      when 'b' then repeat_last(param(0, 1))                         # REP
      when 'I' then forward_tab(param(0, 1)); @wrap_pending = false  # CHT
      when 'Z' then back_tab(param(0, 1))                            # CBT
      when 'g' then tab_clear(param0(0))                             # TBC
      when 'm'
        # Only a *plain* CSI (no private/intermediate prefix) is SGR. A
        # prefixed form like `CSI > 4 ; 2 m` is xterm's modifyOtherKeys
        # ("set key-modifier options"), which vim/neovim/tmux emit at startup —
        # NOT a colour/style change. Running it through `apply_sgr` misread its
        # `4` as SGR underline (and `0`/reset on the matching `CSI > 4 ; 0 m`),
        # so every following glyph was wrongly underlined until the next reset.
        apply_sgr if @csi_prefix.nil?
      when 'r'
        # Only a *plain* `CSI Pt ; Pb r` is DECSTBM (set scroll region). The
        # private form `CSI ? Pm r` is XTRESTORE — restore DEC private mode
        # values, the counterpart to the `CSI ? Pm s` XTSAVE the 's' handler
        # already ignores. xterm-aware children pair them around a mode change
        # (e.g. `CSI ? 7 r` to restore autowrap), so letting the restore fall
        # through to DECSTBM misread its `7` as a top margin and corrupted the
        # scroll region. We don't track saved private modes; the restore is a
        # no-op, but it must NOT be treated as DECSTBM. (We have nothing to
        # intermediate-prefix here, so gate on the plain-CSI `@csi_prefix.nil?`.)
        top = param(0, 1) - 1
        # xterm *clamps* an over-large bottom margin to the last row and still
        # sets the region; it does not reject the request. Rejecting it (the old
        # `bot <= @rows - 1` guard) left a stale region in place — e.g. a child
        # still using its pre-resize row count emits `CSI 1;<oldrows> r` before it
        # processes SIGWINCH, and that DECSTBM was silently dropped, so scrolling
        # stayed confined to the previous (smaller) region until the child caught
        # up. Clamp instead, matching xterm.
        bot = Math.min(param(1, @rows) - 1, @rows - 1)
        if @csi_prefix.nil? && top < bot
          @scroll_top = Math.max(0, top)
          @scroll_bottom = bot
          @x = 0
          @y = @origin_mode ? @scroll_top : 0 # DECSTBM homes the cursor
          @wrap_pending = false
        end
      when 'h' then set_mode true
      when 'l' then set_mode false
      when 's', 'u'
        # SCOSC / SCORC (save/restore cursor) are only the *plain* `CSI s` / `CSI u`.
        # A prefixed form is something else entirely and must NOT move the cursor:
        # the Kitty keyboard protocol — which neovim, fish, kakoune, … negotiate at
        # startup — pushes/pops/queries its flags with `CSI > Pn u`, `CSI < Pn u`,
        # `CSI = Pn ; Pn u` and `CSI ? u`. Gating only on `@csi_private` (the `?`
        # prefix) let `>`/`<`/`=` fall through to `restore_cursor`, so a child
        # toggling Kitty-keyboard mode had its cursor yanked to the last saved
        # position (0,0 if never saved). The same `@csi_prefix.nil?` gate the SGR
        # ('m') handler uses for the modifyOtherKeys form applies here.
        if @csi_prefix.nil?
          c == 's' ? save_cursor : restore_cursor
        end
      when 'n' then device_status(param0(0))
      when 'c'
        if param0(0) == 0
          case @csi_prefix
          when nil then respond("\e[?6c")     # primary DA  (CSI c)   — VT102
          when '>' then respond("\e[>0;0;0c") # secondary DA (CSI > c) — VT100, ver 0
          # tertiary (`=`) / unknown prefix: not answered
          end
        end
      else
        # Unimplemented final byte — ignored.
      end
    end

    private def set_mode(on : Bool) : Nil
      unless @csi_private
        # ANSI (non-private) modes. IRM (4) is the only one acted on: it toggles
        # insert/replace mode (terminfo `smir`/`rmir`), consumed in `#print_char`.
        # The other standard ANSI modes (e.g. LNM 20) are not used by the target
        # programs and are ignored.
        each_csi_param { |mode| @insert_mode = on if mode == 4 }
        return
      end
      each_csi_param do |mode|
        case mode
        when 25       then @cursor_hidden = !on # DECTCEM
        when 47, 1047 then on ? enter_alt(false) : leave_alt(false)
        when 1049     then on ? enter_alt(true) : leave_alt(true)
        when 9        then @mouse_tracking = on ? 9 : 0    # X10
        when 1000     then @mouse_tracking = on ? 1000 : 0 # normal (press/release)
        when 1002     then @mouse_tracking = on ? 1002 : 0 # button-event
        when 1003     then @mouse_tracking = on ? 1003 : 0 # any-event
        when 1005     then @mouse_encoding = on ? :utf8 : :normal
        when 1006     then @mouse_encoding = on ? :sgr : :normal
        when 1015     then @mouse_encoding = on ? :urxvt : :normal
        when 6 # DECOM (origin mode): cursor homes to the (possibly relative) origin
          @origin_mode = on
          @x = 0
          @y = on ? @scroll_top : 0
          @wrap_pending = false
        when 2004 then @bracketed_paste = on
        when 1004 then @focus_reporting = on
        when 7 # DECAWM (autowrap): turning it off cancels any pending wrap too
          @autowrap = on
          @wrap_pending = false unless on
        else
          # 1 (DECCKM), 12 (cursor blink), 1000-series already handled … ignored.
        end
      end
    end

    # Whether the child has requested mouse reporting.
    def mouse_enabled? : Bool
      @mouse_tracking != 0
    end

    # ───────────────────────── alternate window ─────────────────────────

    # Switches to a fresh alternate page, parking the main buffer (and, for 1049,
    # the cursor) until `#leave_alt`.
    private def enter_alt(save_cursor_too : Bool) : Nil
      return if @alt_active
      @alt_active = true
      @main_lines = @lines
      @main_ybase = @ybase
      @main_ydisp = @ydisp
      @main_scroll_top = @scroll_top
      @main_scroll_bottom = @scroll_bottom
      if save_cursor_too
        @alt_saved_x = @x
        @alt_saved_y = @y
        @alt_saved_attr = @cur_attr
      end

      @lines = blank_page
      @ybase = 0
      @ydisp = 0
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @wrap_pending = false
    end

    # Restores the main buffer saved by `#enter_alt` (the alt page is discarded).
    private def leave_alt(restore_cursor_too : Bool) : Nil
      return unless @alt_active
      @alt_active = false
      if ml = @main_lines
        @lines = ml
      end
      @main_lines = nil
      @ybase = @main_ybase
      @ydisp = @main_ydisp
      @scroll_top = @main_scroll_top
      @scroll_bottom = @main_scroll_bottom
      if restore_cursor_too
        @x = clamp(@alt_saved_x, 0, @cols - 1)
        @y = clamp(@alt_saved_y, 0, @rows - 1)
        @cur_attr = @alt_saved_attr
      end
      @wrap_pending = false
    end

    # 1-based cursor row for a CPR/DECXCPR reply. Under origin mode (DECOM) the
    # cursor row is addressed relative to the scroll region's top (see `#set_row`),
    # so the report must be relative too — otherwise a child that homes with
    # origin coords and then reads the position back gets a row that doesn't match
    # the one it just set. The column is unaffected (no left/right margins here).
    private def cpr_row : Int32
      @origin_mode ? (@y - @scroll_top + 1) : (@y + 1)
    end

    private def device_status(code : Int32) : Nil
      if @csi_private
        # DEC-private DSR (DECDSR): the reply mirrors the request's `?` prefix.
        case code
        when 6 then respond("\e[?#{cpr_row};#{@x + 1}R") # DECXCPR (extended CPR)
        end
      else
        case code
        when 5 then respond("\e[0n")                    # "OK"
        when 6 then respond("\e[#{cpr_row};#{@x + 1}R") # cursor position (CPR)
        end
      end
    end

    private def respond(s : String) : Nil
      if out = @output
        out.print s
        out.flush
      end
    end

    private def apply_sgr : Nil
      # Parse the bare parameter list (`@csi_buf`) directly, instead of rebuilding
      # a framed `"\e[" + @csi_buf + "m"` string only to have `attr2code`
      # re-scan it — one fewer `String` allocation per SGR sequence.
      @cur_attr = Crysterm::Screen.attr2code_params(@csi_buf.to_slice, @cur_attr, @default_attr)
    end

    # ───────────────────────── editing primitives ─────────────────────────

    private def print_char(c : Char) : Nil
      # Translate through the line-drawing set when the active charset is special.
      if (@gl == 0 ? @g0_special : @g1_special)
        c = DEC_GRAPHICS[c]? || c
      end

      w = ::Crysterm::Unicode.width c
      w = 1 if w < 1 # zero-width / control: place as a single cell (no combining yet)

      if @wrap_pending
        @x = 0
        line_feed
        @wrap_pending = false
      end

      # A wide glyph that would overrun the last column wraps to the next line,
      # leaving the final column blank (matching xterm) — but only when autowrap
      # is on; otherwise it overwrites the last column in place below.
      if @autowrap && w == 2 && @x == @cols - 1
        cur_line[@x] = Cell.new(@cur_attr, ' ')
        @x = 0
        line_feed
      end

      line = cur_line
      if @insert_mode
        # IRM: open w cells at the cursor — shift the tail of the line right by w,
        # dropping the cells pushed past the end — so the glyph is inserted rather
        # than overwriting. The same in-place shift `#insert_chars` (ICH) performs,
        # applied per printed character.
        i = line.size - 1
        while i - w >= @x
          line[i] = line[i - w]
          i -= 1
        end
      end
      line[@x] = Cell.new(@cur_attr, c)
      @last_char = c # remember the placed glyph so REP ('b') can repeat it
      if w == 2 && @x + 1 < @cols
        line[@x + 1] = Cell.new(@cur_attr, CONTINUATION)
      end

      if @x + w >= @cols
        # Park on the last column. With autowrap on, defer the wrap (the next
        # glyph triggers it); with autowrap off, just stick there so the next
        # glyph overwrites this cell instead of advancing the window.
        @x = @cols - 1
        @wrap_pending = @autowrap
      else
        @x += w
      end
    end

    # REP (`CSI Pn b`): re-emit the last graphic character *n* more times, exactly
    # as if it had been typed again (so it advances the cursor and wraps normally).
    # A no-op when no graphic character has been printed yet. The count is capped
    # at the grid area — repeating beyond a full window is pointless, and the cap
    # keeps an adversarial `CSI 99999999 b` from spinning O(n), the same guard the
    # SU/IL/ICH handlers apply.
    private def repeat_last(n : Int32) : Nil
      c = @last_char || return
      n = Math.min(n, @cols * @rows)
      n.times { print_char c }
    end

    private def backspace : Nil
      @x -= 1 if @x > 0
      @wrap_pending = false
    end

    # HT: advance to the next tab stop to the right of the cursor, or to the last
    # column when none remains. Honours the (possibly customized) `@tab_stops`
    # rather than a hardcoded width.
    private def tab : Nil
      x = @x + 1
      while x < @cols && !@tab_stops.includes?(x)
        x += 1
      end
      @x = Math.min(x, @cols - 1)
      @wrap_pending = false
    end

    # CHT: advance *n* tab stops.
    private def forward_tab(n : Int32) : Nil
      n.times { tab }
    end

    # CBT: move back *n* tab stops (stopping at column 0).
    private def back_tab(n : Int32) : Nil
      n.times do
        x = @x - 1
        while x > 0 && !@tab_stops.includes?(x)
          x -= 1
        end
        @x = x < 0 ? 0 : x
      end
      @wrap_pending = false
    end

    # TBC: clear the tab stop at the cursor (mode 0) or all stops (mode 3).
    private def tab_clear(mode : Int32) : Nil
      case mode
      when 0 then @tab_stops.delete cursor_x
      when 3 then @tab_stops.clear
      end
    end

    private def line_feed : Nil
      @wrap_pending = false
      if @y == @scroll_bottom
        scroll_up
      elsif @y < @rows - 1
        @y += 1
      end
    end

    private def reverse_index : Nil
      # RI repositions the active line, so it cancels any deferred (last-column)
      # wrap — exactly as its mirror IND (`#line_feed`) and every CSI cursor move
      # do. Without this, a glyph printed right after RI on a just-filled row saw
      # the stale `@wrap_pending` and spuriously wrapped to the next line instead
      # of overwriting at the cursor's actual column.
      @wrap_pending = false
      if @y == @scroll_top
        scroll_down
      elsif @y > 0
        @y -= 1
      end
    end

    # Runs *block* (one scroll step) at most *n* times, capped at the scroll
    # region's height. SU/SD by more than the region's height leaves the region
    # fully blank either way, so the surplus is a no-op — but the raw
    # `param.times` would still iterate it: an adversarial `CSI 99999999 S` would
    # then spin O(n) (and, on a full-window region, push n blank lines toward the
    # scrollback limit), tearing through the reader fiber. This is the same cap
    # `#insert_lines`/`#delete_lines` apply to IL/DL.
    private def scroll_region_times(n : Int32, &) : Nil
      n = Math.min(n, @scroll_bottom - @scroll_top + 1)
      n.times { yield }
    end

    # Scrolls the scroll-region up by one line (content moves up; blank at
    # bottom). When the region is the whole window, the displaced top line is
    # pushed into scrollback instead of being discarded.
    private def scroll_up : Nil
      if @scroll_top == 0 && @scroll_bottom == @rows - 1
        # The alternate window has NO scrollback (matching xterm): a full-window
        # scroll discards the displaced top line rather than retaining it. Recycle
        # its `Array(Cell)` storage in place as the new bottom row, so the alt page
        # never grows `@lines`/`@ybase` (unbounded memory while a full-window app
        # scrolls) and never exposes bogus "history" to scrollback navigation.
        if @alt_active
          recycle_top_row
          return
        end
        # xterm holds the scrollback position when fresh output arrives while the
        # user is scrolled back; the view only follows the live bottom when it is
        # already there. `follow` captures "at bottom" *before* `@ybase` moves.
        follow = @ydisp == @ybase
        if @lines.size - @rows >= SCROLLBACK_LIMIT
          # Scrollback is already full — the steady state while a child streams
          # output. Rather than allocate a fresh `blank_line` for the new bottom
          # row and let the shifted-off top line become garbage, recycle that
          # line's `Array(Cell)` storage: `shift` it, blank it in place, and
          # `push` it back as the new bottom row. The resulting `@lines` (and
          # `@ybase`, left unchanged) are identical to the old push-then-trim, but
          # this path now allocates nothing on every scrolled line.
          recycle_top_row
          # Every row shifted up by one, so a held scrollback view shifts with it
          # (clamped at the top) to stay on the same content.
          @ydisp -= 1 unless follow || @ydisp == 0
        else
          @lines << blank_line
          @ybase += 1
        end
        @ydisp = @ybase if follow
      else
        top = @ybase + @scroll_top
        bot = @ybase + @scroll_bottom
        @lines.delete_at top
        @lines.insert bot, blank_line
      end
    end

    private def scroll_down : Nil
      top = @ybase + @scroll_top
      bot = @ybase + @scroll_bottom
      @lines.delete_at bot
      @lines.insert top, blank_line
    end

    private def erase_display(mode : Int32) : Nil
      case mode
      when 0 # cursor → end of window
        erase_in_line @x, @cols - 1
        ((@y + 1)...@rows).each { |yy| clear_screen_line yy }
      when 1 # start of window → cursor
        (0...@y).each { |yy| clear_screen_line yy }
        erase_in_line 0, @x
      when 2 # whole visible window (scrollback retained)
        (0...@rows).each { |yy| clear_screen_line yy }
      when 3
        # ED 3 (xterm "Erase Saved Lines"): discard the scrollback ONLY; the
        # visible page is left intact. This previously also cleared the visible
        # rows (treating ED 3 as ED 2 + scrollback), so a child that sent a bare
        # `CSI 3 J` to trim history — without the usual following `CSI 2 J` —
        # wrongly lost its on-window content. Keep the live rows (they are exactly
        # `@lines[@ybase, @rows]`); just drop everything above them.
        @lines = @lines[@ybase, @rows].dup
        @ybase = 0
        @ydisp = 0
      end
    end

    private def erase_line(mode : Int32) : Nil
      case mode
      when 0 then erase_in_line @x, @cols - 1 # cursor → eol
      when 1 then erase_in_line 0, @x         # sol → cursor
      when 2 then erase_in_line 0, @cols - 1  # whole line
      end
    end

    private def clear_screen_line(yy : Int32) : Nil
      @lines[@ybase + yy] = blank_line
    end

    private def erase_in_line(from : Int32, to : Int32) : Nil
      line = cur_line
      ea = erase_attr
      blank = Cell.new(ea, ' ')
      (from..to).each do |xx|
        line[xx] = blank if xx < line.size
      end
    end

    # IL: open *n* blank lines at the cursor inside the scroll region, pushing the
    # rest down (lines below the region's bottom are lost). *n* is capped at the
    # lines from the cursor to the region bottom — a larger count just blanks the
    # whole region below the cursor, so the surplus is a no-op — so an adversarial
    # `CSI 99999 L` can't spin in O(n·height) (nor allocate *n* blank lines), the
    # same cap `#insert_chars`/`#delete_chars` apply on the row.
    private def insert_lines(n : Int32) : Nil
      return unless @y >= @scroll_top && @y <= @scroll_bottom
      # IL moves the active position to the line home position (ECMA-48: "the
      # active presentation position is moved to the line home position"), as
      # xterm and modern terminals do. Without it the cursor was left at its old
      # column, so a child that does `CSI L` and then prints — expecting the text
      # at the left margin per spec, with no explicit CR — landed it mid-line.
      @x = 0
      @wrap_pending = false
      n = Math.min(n, @scroll_bottom - @y + 1)
      return if n <= 0
      bot = @ybase + @scroll_bottom
      n.times do
        @lines.delete_at bot
        @lines.insert @ybase + @y, blank_line
      end
    end

    # DL: remove *n* lines at the cursor inside the scroll region, pulling the rest
    # up and backfilling the bottom with blanks. Same cap as `#insert_lines`.
    private def delete_lines(n : Int32) : Nil
      return unless @y >= @scroll_top && @y <= @scroll_bottom
      # DL, like IL, moves the active position to the line home position (ECMA-48).
      @x = 0
      @wrap_pending = false
      n = Math.min(n, @scroll_bottom - @y + 1)
      return if n <= 0
      bot = @ybase + @scroll_bottom
      n.times do
        @lines.delete_at @ybase + @y
        @lines.insert bot, blank_line
      end
    end

    # ICH: open *n* blank cells at the cursor, shifting the rest of the line right
    # (cells pushed past the end are lost). A single in-place shift — capping *n*
    # at the cells from the cursor to the line end (a larger count just blanks the
    # whole tail, so the surplus is a no-op) — instead of *n* O(width) `Array#insert`
    # calls, so an adversarial `CSI 99999 @` can't spin in O(n·width).
    private def insert_chars(n : Int32) : Nil
      line = cur_line
      n = Math.min(n, line.size - @x)
      return if n <= 0
      blank = Cell.new(erase_attr, ' ')
      i = line.size - 1
      while i - n >= @x
        line[i] = line[i - n]
        i -= 1
      end
      while i >= @x
        line[i] = blank
        i -= 1
      end
    end

    # DCH: remove *n* cells at the cursor, shifting the rest of the line left and
    # backfilling the end with blanks. Same single in-place shift / cap as
    # `#insert_chars`.
    private def delete_chars(n : Int32) : Nil
      line = cur_line
      n = Math.min(n, line.size - @x)
      return if n <= 0
      blank = Cell.new(erase_attr, ' ')
      i = @x
      while i + n < line.size
        line[i] = line[i + n]
        i += 1
      end
      while i < line.size
        line[i] = blank
        i += 1
      end
    end

    private def erase_chars(n : Int32) : Nil
      erase_in_line @x, Math.min(@cols - 1, @x + n - 1)
    end

    private def save_cursor : Nil
      @saved_x = @x
      @saved_y = @y
      @saved_attr = @cur_attr
      @saved_g0_special = @g0_special
      @saved_g1_special = @g1_special
      @saved_gl = @gl
      @saved_origin_mode = @origin_mode
      @saved_autowrap = @autowrap
    end

    private def restore_cursor : Nil
      @x = clamp(@saved_x, 0, @cols - 1)
      @y = clamp(@saved_y, 0, @rows - 1)
      @cur_attr = @saved_attr
      @g0_special = @saved_g0_special
      @g1_special = @saved_g1_special
      @gl = @saved_gl
      @origin_mode = @saved_origin_mode
      @autowrap = @saved_autowrap
      @wrap_pending = false
    end

    private def full_reset : Nil
      @cur_attr = @default_attr
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @x = 0
      @y = 0
      @wrap_pending = false
      @autowrap = true
      @insert_mode = false
      @last_char = nil
      @cursor_hidden = false
      @lines = blank_page
      @ybase = 0
      @ydisp = 0
      @g0_special = false
      @g1_special = false
      @gl = 0
      @alt_active = false
      @main_lines = nil
      @mouse_tracking = 0
      @mouse_encoding = :normal
      @origin_mode = false
      @bracketed_paste = false
      @focus_reporting = false
      reset_tab_stops
    end

    # ───────────────────────── geometry / queries ─────────────────────────

    # Pads or trims *grid* so its viewport (the lines from *base* onward) holds
    # exactly *rows* lines: growing appends blank lines, shrinking drops the
    # lines that fell off the bottom of the smaller viewport (content is kept at
    # the top-left). Used on resize for both the live grid and the parked main
    # buffer.
    private def fit_viewport(grid : Array(Array(Cell)), base : Int32, rows : Int32) : Nil
      screen_lines = grid.size - base
      if screen_lines < rows
        (rows - screen_lines).times { grid << blank_line }
      elsif screen_lines > rows
        grid.pop(screen_lines - rows)
      end
    end

    # Resizes the grid. Content is preserved at the top-left; rows/cols are
    # padded with blanks or truncated. (A faithful reflow is out of scope for
    # v1; this matches the pragmatic behaviour of most emulators on resize.)
    def resize(cols : Int32, rows : Int32) : Nil
      cols = 1 if cols < 1
      rows = 1 if rows < 1
      return if cols == @cols && rows == @rows

      @cols = cols
      @rows = rows

      ea = erase_attr
      # Adjust the live grid and, when on the alt page, the parked main buffer
      # too — otherwise restoring it after a resize would yield ragged rows.
      ({@lines, @main_lines}).each do |grid|
        next unless grid
        grid.each do |line|
          if line.size < cols
            (cols - line.size).times { line.push Cell.new(ea, ' ') }
          elsif line.size > cols
            line.pop(line.size - cols)
          end
        end
      end

      # Ensure the viewport holds exactly `rows` lines. Growing pads with blanks;
      # shrinking drops the lines that fell off the bottom of the smaller viewport
      # (content is preserved at the top-left, matching the per-line column
      # truncation above). Without the trim those rows linger past the live window,
      # and a later full-window `scroll_up` — which appends at the end of `@lines`
      # and advances `@ybase` — would shift them back into view instead of the
      # freshly scrolled-in blank.
      fit_viewport @lines, @ybase, rows

      # When on the alt page, grow the parked main buffer's viewport too (it uses
      # the saved `@main_ybase`); otherwise a grow-resize leaves `@main_lines`
      # short and restoring it after `#leave_alt` would yield a truncated window.
      if ml = @main_lines
        fit_viewport ml, @main_ybase, rows
        # A resize resets the scroll margins to the full window on the active page
        # (just below). Do the same to the *parked* main page, otherwise leaving
        # the alt window after a resize would restore a stale (pre-resize) scroll
        # region — e.g. quitting vim after the window grew would leave the shell
        # scrolling inside the old, smaller region.
        @main_scroll_top = 0
        @main_scroll_bottom = rows - 1
      end

      @scroll_top = 0
      @scroll_bottom = rows - 1
      @x = clamp(@x, 0, cols - 1)
      @y = clamp(@y, 0, rows - 1)
      @wrap_pending = false
      @ydisp = @ybase
      # Re-establish default stops for the new width (matching the scroll-region
      # reset above; custom stops don't survive a resize, as in most emulators).
      reset_tab_stops
    end

    # Cursor column for rendering (deferred-wrap aware: never reported past the
    # last column).
    def cursor_x : Int32
      Math.min(@x, @cols - 1)
    end

    def cursor_y : Int32
      @y
    end

    # Scrollback controls (mirroring blessed's Terminal scroll API).
    def scroll_to(offset : Int32) : Nil
      @ydisp = clamp(offset, 0, @ybase)
    end

    def scroll(offset : Int32) : Nil
      @ydisp = clamp(@ydisp + offset, 0, @ybase)
    end

    def reset_scroll : Nil
      @ydisp = @ybase
    end

    def scroll_perc : Float64
      @ybase == 0 ? 0.0 : (@ydisp.to_f / @ybase) * 100
    end

    private def clamp(v : Int32, lo : Int32, hi : Int32) : Int32
      hi = lo if hi < lo
      v < lo ? lo : (v > hi ? hi : v)
    end
  end
end
