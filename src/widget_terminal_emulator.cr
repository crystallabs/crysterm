module Crysterm
  # A self-contained VT100/xterm-subset terminal emulator.
  #
  # SUPPORTING CODE — like `Pty`, this has no dependency on the widget tree and
  # is a candidate for extraction into its own shard. It is the Crystal-side
  # counterpart of the `term.js` library that blessed's `terminal` widget drove:
  # it consumes the raw byte stream a child program writes to a PTY and maintains
  # an in-memory grid of cells (attribute + character) that a renderer can copy
  # onto the screen.
  #
  # Scope: it implements the sequences a normal interactive shell and the common
  # full-screen programs (vim, htop, less, top, man) rely on — cursor movement,
  # SGR colours/styles, erase/insert/delete, scroll regions and scrollback,
  # cursor save/restore, title (OSC 0/2), the basic device-status/attributes
  # replies, the alternate screen buffer (DECSET 47/1047/1049), the DEC
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

    # All lines, scrollback first; the live screen is the `rows` lines starting
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
    # Called after each `#feed` so the owner can request a screen render.
    property on_refresh : Proc(Nil)? = nil

    @default_attr : Int64
    @cur_attr : Int64

    @scroll_top : Int32 = 0
    @scroll_bottom : Int32 = 0

    @saved_x : Int32 = 0
    @saved_y : Int32 = 0
    @saved_attr : Int64

    # Deferred wrap: after writing the last column we stay on it until the next
    # printable char, matching xterm (prevents a spurious blank line when text
    # exactly fills a row).
    @wrap_pending : Bool = false

    # Parser state. The CSI/OSC accumulation buffers are reused `IO::Memory`s
    # (cleared, not reallocated, at the start of each sequence): a child redrawing
    # a full screen emits a CSI per cursor move / colour change, and the old
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

    # Alternate-screen state (DECSET 47/1047/1049). When active, `@lines` is a
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
    # emulator grid. Matches `Screen::Cell::CONTINUATION` so the widget can copy
    # the notion straight through to the screen's own continuation cells.
    CONTINUATION = '\u0000' # NUL — same sentinel as Screen::Cell::CONTINUATION

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
      @lines = Array(Array(Cell)).new
      @rows.times { @lines << blank_line }
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
      String.new(complete).each_char { |c| handle_char c }

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
        print_char c if c.ord >= 0x20
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
      when 'P', 'X', '^', '_'
        # DCS/SOS/PM/APC string — swallow like an OSC (until ST/BEL), but flag it
        # so the payload is discarded rather than parsed as an OSC title.
        @state = :osc
        @osc_buf.clear
        @osc_esc = false
        @osc_string = true
      when '7' then save_cursor; @state = :ground
      when '8' then restore_cursor; @state = :ground
      when 'M' then reverse_index; @state = :ground     # RI
      when 'D' then line_feed; @state = :ground         # IND
      when 'E' then @x = 0; line_feed; @state = :ground # NEL
      when 'c' then full_reset; @state = :ground        # RIS
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

    # The n-th `;`-separated parameter in `@csi_buf` (0-based), parsed in place,
    # or nil when there is no n-th field. An empty or non-numeric field reads as
    # 0, matching the old `split(';').map { |s| s.to_i? || 0 }`. No allocation —
    # this replaces the per-CSI `Array(String)` + `Array(Int32)` that `split`/
    # `map` produced on every cursor move / SGR change a full-screen child emits.
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
          val = val * 10 + (b - '0'.ord)
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
          val = val * 10 + (b - '0'.ord)
        else
          bad = true
        end
        idx += 1
      end
      yield(bad ? 0 : val)
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
      when 'A'      then @y = Math.max(0, @y - param(0, 1)); @wrap_pending = false
      when 'B'      then @y = Math.min(@rows - 1, @y + param(0, 1)); @wrap_pending = false
      when 'C'      then @x = Math.min(@cols - 1, @x + param(0, 1)); @wrap_pending = false
      when 'D'      then @x = Math.max(0, @x - param(0, 1)); @wrap_pending = false
      when 'E'      then @x = 0; @y = Math.min(@rows - 1, @y + param(0, 1))
      when 'F'      then @x = 0; @y = Math.max(0, @y - param(0, 1))
      when 'G', '`' then @x = clamp(param(0, 1) - 1, 0, @cols - 1); @wrap_pending = false
      when 'd'      then set_row(param(0, 1) - 1)
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
      when 'S' then param(0, 1).times { scroll_up }
      when 'T' then param(0, 1).times { scroll_down }
      when 'm' then apply_sgr
      when 'r'
        top = param(0, 1) - 1
        bot = param(1, @rows) - 1
        if top < bot && bot <= @rows - 1
          @scroll_top = Math.max(0, top)
          @scroll_bottom = Math.min(@rows - 1, bot)
          @x = 0
          @y = @origin_mode ? @scroll_top : 0 # DECSTBM homes the cursor
        end
      when 'h' then set_mode true
      when 'l' then set_mode false
      when 's' then save_cursor unless @csi_private
      when 'u' then restore_cursor unless @csi_private
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
      return unless @csi_private
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
        when 2004 then @bracketed_paste = on
        when 1004 then @focus_reporting = on
        else
          # 1 (DECCKM), 12 (cursor blink), 1000-series already handled … ignored.
        end
      end
    end

    # Whether the child has requested mouse reporting.
    def mouse_enabled? : Bool
      @mouse_tracking != 0
    end

    # ───────────────────────── alternate screen ─────────────────────────

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

      @lines = Array(Array(Cell)).new
      @rows.times { @lines << blank_line }
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

    private def device_status(code : Int32) : Nil
      if @csi_private
        # DEC-private DSR (DECDSR): the reply mirrors the request's `?` prefix.
        case code
        when 6 then respond("\e[?#{@y + 1};#{@x + 1}R") # DECXCPR (extended CPR)
        end
      else
        case code
        when 5 then respond("\e[0n")                   # "OK"
        when 6 then respond("\e[#{@y + 1};#{@x + 1}R") # cursor position (CPR)
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
      # leaving the final column blank (matching xterm).
      if w == 2 && @x == @cols - 1
        cur_line[@x] = Cell.new(@cur_attr, ' ')
        @x = 0
        line_feed
      end

      line = cur_line
      line[@x] = Cell.new(@cur_attr, c)
      if w == 2 && @x + 1 < @cols
        line[@x + 1] = Cell.new(@cur_attr, CONTINUATION)
      end

      if @x + w >= @cols
        @x = @cols - 1
        @wrap_pending = true
      else
        @x += w
      end
    end

    private def backspace : Nil
      @x -= 1 if @x > 0
      @wrap_pending = false
    end

    private def tab : Nil
      @x = Math.min(@cols - 1, (@x // 8 + 1) * 8)
      @wrap_pending = false
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
      if @y == @scroll_top
        scroll_down
      elsif @y > 0
        @y -= 1
      end
    end

    # Scrolls the scroll-region up by one line (content moves up; blank at
    # bottom). When the region is the whole screen, the displaced top line is
    # pushed into scrollback instead of being discarded.
    private def scroll_up : Nil
      if @scroll_top == 0 && @scroll_bottom == @rows - 1
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
          recycled = @lines.shift
          blank_in_place recycled
          @lines << recycled
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
      when 0 # cursor → end of screen
        erase_in_line @x, @cols - 1
        ((@y + 1)...@rows).each { |yy| clear_screen_line yy }
      when 1 # start of screen → cursor
        (0...@y).each { |yy| clear_screen_line yy }
        erase_in_line 0, @x
      when 2, 3 # whole screen (3 also clears scrollback)
        (0...@rows).each { |yy| clear_screen_line yy }
        if mode == 3
          @lines = @lines[@ybase, @rows].dup
          @ybase = 0
          @ydisp = 0
        end
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

    private def insert_lines(n : Int32) : Nil
      return unless @y >= @scroll_top && @y <= @scroll_bottom
      bot = @ybase + @scroll_bottom
      n.times do
        @lines.delete_at bot
        @lines.insert @ybase + @y, blank_line
      end
    end

    private def delete_lines(n : Int32) : Nil
      return unless @y >= @scroll_top && @y <= @scroll_bottom
      bot = @ybase + @scroll_bottom
      n.times do
        @lines.delete_at @ybase + @y
        @lines.insert bot, blank_line
      end
    end

    private def insert_chars(n : Int32) : Nil
      line = cur_line
      ea = erase_attr
      n.times do
        line.insert @x, Cell.new(ea, ' ')
        line.pop
      end
    end

    private def delete_chars(n : Int32) : Nil
      line = cur_line
      ea = erase_attr
      n.times do
        line.delete_at @x if @x < line.size
        line.push Cell.new(ea, ' ')
      end
    end

    private def erase_chars(n : Int32) : Nil
      erase_in_line @x, Math.min(@cols - 1, @x + n - 1)
    end

    private def save_cursor : Nil
      @saved_x = @x
      @saved_y = @y
      @saved_attr = @cur_attr
    end

    private def restore_cursor : Nil
      @x = clamp(@saved_x, 0, @cols - 1)
      @y = clamp(@saved_y, 0, @rows - 1)
      @cur_attr = @saved_attr
      @wrap_pending = false
    end

    private def full_reset : Nil
      @cur_attr = @default_attr
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @x = 0
      @y = 0
      @wrap_pending = false
      @cursor_hidden = false
      @lines = Array(Array(Cell)).new
      @rows.times { @lines << blank_line }
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
    end

    # ───────────────────────── geometry / queries ─────────────────────────

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

      # Ensure the viewport holds exactly `rows` lines.
      screen_lines = @lines.size - @ybase
      if screen_lines < rows
        (rows - screen_lines).times { @lines << blank_line }
      end

      # When on the alt page, grow the parked main buffer's viewport too (it uses
      # the saved `@main_ybase`); otherwise a grow-resize leaves `@main_lines`
      # short and restoring it after `#leave_alt` would yield a truncated screen.
      if ml = @main_lines
        main_screen_lines = ml.size - @main_ybase
        if main_screen_lines < rows
          (rows - main_screen_lines).times { ml << blank_line }
        end
      end

      @scroll_top = 0
      @scroll_bottom = rows - 1
      @x = clamp(@x, 0, cols - 1)
      @y = clamp(@y, 0, rows - 1)
      @wrap_pending = false
      @ydisp = @ybase
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
