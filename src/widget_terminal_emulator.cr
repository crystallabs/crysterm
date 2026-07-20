module Crysterm
  # A self-contained VT100/xterm-subset terminal emulator. No dependency on the
  # widget tree: it consumes the raw byte stream a child writes to a PTY and
  # maintains an in-memory grid of cells (attribute + character) a renderer can
  # copy onto the window.
  #
  # Scope: the sequences a normal shell and common full-window programs (vim,
  # htop, less, top, man) rely on — cursor movement, SGR colours/styles,
  # erase/insert/delete, scroll regions and scrollback, cursor save/restore
  # (DECSC/DECRC and DECSET 1048), title (OSC 0/2), basic device-status/attributes
  # replies (DSR, primary/secondary DA, DECREQTPARM), the alternate buffer (DECSET
  # 47/1047/1049), the DEC special-graphics charset (`ESC ( 0`), the screen-
  # alignment pattern (DECALN, `ESC # 8`), and mouse-mode tracking. Conformance is
  # exercised against Paul Williams' `vttest`. Does NOT implement double-width/
  # height lines, 132-column mode (DECCOLM), VT52 mode, or G2/G3 charset
  # invocation (noted at each site).
  class TerminalEmulator
    # One grid cell. Must stay a `struct`, so an `Array(Cell)` holds cells inline
    # in one contiguous buffer rather than `@cols` heap objects per line — that
    # allocation dominates the scroll path. Since `arr[x]` is therefore a *copy*,
    # cells are never mutated through the index; writers replace the whole cell.
    struct Cell
      property attr : Int64
      property char : Char

      def initialize(@attr : Int64, @char : Char)
      end
    end

    # The DECSC/DECRC (`ESC 7`/`ESC 8`) save slot as one value, so parking and
    # unparking a per-buffer slot is a single copy.
    struct SavedCursor
      property x : Int32
      property y : Int32
      property attr : Int64
      property g0_special : Bool
      property g1_special : Bool
      property gl : Int32
      property origin_mode : Bool
      property autowrap : Bool
      property wrap_pending : Bool

      def initialize(@x, @y, @attr, @g0_special, @g1_special, @gl, @origin_mode, @autowrap, @wrap_pending)
      end

      # A fresh slot: home cursor, given default rendition, ASCII charset (G0/G1
      # non-special, GL→G0), origin mode off, autowrap on, no pending wrap.
      def self.default(default_attr : Int64) : SavedCursor
        new(0, 0, default_attr, false, false, 0, false, true, false)
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

    # Block forms of the notification setters, e.g. `em.on_title { |t| ... }`.
    def on_bell(&block : ->) : Nil
      @on_bell = block
    end

    # :ditto:
    def on_title(&block : String ->) : Nil
      @on_title = block
    end

    # :ditto:
    def on_refresh(&block : ->) : Nil
      @on_refresh = block
    end

    getter default_attr : Int64
    @cur_attr : Int64

    @scroll_top : Int32 = 0
    @scroll_bottom : Int32 = 0

    # The live DECSC (`ESC 7`) save slot restored by DECRC (`ESC 8`). Per DEC
    # STD-070/xterm this snapshots more than the cursor position: rendition,
    # charset designations (G0/G1 special) and active GL invocation, origin mode
    # (DECOM), autowrap (DECAWM) and the pending-wrap flag are all DECSC state.
    @saved : SavedCursor

    # Deferred wrap: after writing the last column we stay on it until the next
    # printable char, matching xterm (prevents a spurious blank line when text
    # exactly fills a row).
    @wrap_pending : Bool = false

    # Autowrap mode (DECAWM, DECSET ?7): when on (the default), a glyph past the
    # last column wraps to the next line. When off (`CSI ? 7 l`), the cursor
    # *sticks* at the last column and further glyphs overwrite it — the standard
    # way to paint the bottom-right cell or a full-width status line without
    # triggering a scroll.
    @autowrap = true

    # Insert/replace mode (IRM, ANSI mode 4, `CSI 4 h`/`CSI 4 l`; terminfo
    # `smir`/`rmir`). When on, a printed glyph is *inserted* at the cursor (rest
    # of line shifts right, overflow drops) instead of overwriting in place.
    @insert_mode = false

    # The last graphic character placed in the grid (after charset translation),
    # so REP (`CSI Pn b`) can repeat it.
    @last_char : Char? = nil

    # Parser state. The CSI/OSC accumulation buffers must stay reused
    # `IO::Memory`s, cleared rather than reallocated per sequence: a `@csi_buf +=
    # c` would allocate a `String` per byte, making a long OSC payload (e.g.
    # OSC 52 clipboard) quadratic.
    @state : Symbol = :ground
    @csi_buf = IO::Memory.new
    @csi_private : Bool = false
    # Leading private/intermediate prefix byte of the current CSI (`<`, `=`, `>`
    # or `?`, 0x3c-0x3f), or nil for a plain CSI. Kept out of `@csi_buf` so
    # parameter parsing stays numeric, and so `c`/`n` finals can tell a secondary
    # DA (`CSI > c`) or DEC-private DSR (`CSI ? 6 n`) from their plain forms.
    @csi_prefix : Char? = nil
    # True once an intermediate byte (0x20-0x2f, e.g. the `$` of DECCARA
    # `CSI … $ r` or the SP of SL `CSI … SP @`) has been seen in the current CSI.
    # No CSI final implemented here takes an intermediate, and the final byte alone
    # collides with an unrelated command (`$ r` vs DECSTBM `r`, `SP @` vs ICH `@`),
    # so a sequence carrying one must be ignored. Kept out of `@csi_buf` so
    # parameter parsing stays numeric.
    @csi_intermediate : Bool = false
    @osc_buf = IO::Memory.new
    @osc_esc : Bool = false
    # True while the string is a DCS/SOS/PM/APC payload (entered via
    # `ESC P`/`X`/`^`/`_`) rather than a real OSC (`ESC ]`). Swallowed to its
    # terminator but NOT parsed as a window title (else e.g. a sixel
    # `ESC P 0;1;0 q …` would be mistaken for an OSC 0 title set).
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

    # Horizontal tab stops: the columns HT/CHT advance *to* (and CBT backs up
    # to). Defaults to every 8th column; a child can add a stop at the cursor
    # with HTS (`ESC H`) and clear with TBC (`CSI g`).
    @tab_stops = Set(Int32).new

    # Alternate-window state (DECSET 47/1047/1049). When active, `@lines` is a
    # fresh page and the main buffer is parked in `@main_*` until restored.
    getter? alt_active : Bool = false
    @main_lines : Array(Array(Cell))? = nil
    @main_ybase = 0
    @main_ydisp = 0
    @main_scroll_top = 0
    @main_scroll_bottom = 0
    # The DECSC/DECRC save slot is *per-buffer*, matching xterm: entering the alt
    # screen parks the main buffer's slot here and gives the alt buffer a fresh
    # one, so a DECSC on one screen can't restore onto the other. 1048/1049 use
    # this same slot (not a private one), so `CSI ? 1049 h` overwrites a prior
    # `ESC 7` and a later `ESC 8` sees the 1049-saved cursor — as in xterm.
    @main_saved : SavedCursor

    # How mouse reports are framed on the wire, selected by the child via
    # DECSET 1005 (`Utf8`), 1006 (`Sgr`) or 1015 (`Urxvt`); `Normal` is the
    # legacy X10 byte framing.
    enum MouseEncoding
      Normal
      Sgr
      Utf8
      Urxvt
    end

    # Mouse tracking requested by the child. `@mouse_tracking` is the active
    # DECSET tracking mode (0 = off, else 9/1000/1002/1003); `@mouse_encoding`
    # is how reports are framed (see `MouseEncoding`).
    getter mouse_tracking : Int32 = 0
    getter mouse_encoding : MouseEncoding = MouseEncoding::Normal

    # Origin mode (DECOM, DECSET ?6): when on, row addressing (CUP/VPA) is
    # relative to the scroll region's top and the cursor cannot leave it.
    @origin_mode = false

    # Bracketed-paste (?2004) and focus-reporting (?1004) modes. The emulator
    # only tracks them; the widget acts on them (wrapping pasted input / emitting
    # focus reports).
    getter? bracketed_paste : Bool = false
    getter? focus_reporting : Bool = false

    # Sentinel char marking the trailing half of a wide (2-column) glyph. Must
    # stay equal to `Window::Cell::CONTINUATION`, so the widget can copy the
    # notion straight through to the window's own continuation cells.
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
      @saved = SavedCursor.default(default_attr)
      @main_saved = SavedCursor.default(default_attr)
      @scroll_bottom = @rows - 1
      @lines = blank_page
      reset_tab_stops
    end

    # Resets the horizontal tab stops to the default — one every 8 columns — for
    # the current width.
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

    # A fresh page of `@rows` blank lines at the current width/erase attr.
    private def blank_page : Array(Array(Cell))
      page = Array(Array(Cell)).new
      @rows.times { page << blank_line }
      page
    end

    # Overwrites every cell of an existing line with the current erase blank,
    # reusing the line's storage so recycling a scrolled-off line allocates nothing.
    private def blank_in_place(line : Array(Cell)) : Nil
      refill_line line, Cell.new(erase_attr, ' ')
    end

    # Overwrites an existing line with `cell`, reusing the line's storage and
    # re-fitting to `@cols` should the line's length have drifted from the current
    # width (e.g. a mid-stream resize).
    private def refill_line(line : Array(Cell), cell : Cell) : Nil
      if line.size == @cols
        line.fill cell
      else
        line.clear
        @cols.times { line << cell }
      end
    end

    # Recycles the top line's `Array(Cell)` storage as a fresh blank bottom row,
    # so a full-window scroll that discards the top line allocates nothing.
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

      # Fast path: terminal output is overwhelmingly ASCII, so feed those bytes
      # straight as chars without materializing a `String` (control/escape bytes
      # are all ASCII, so the parser is unaffected). A multibyte glyph is decoded
      # in place and the ASCII loop resumes.
      ptr = complete.to_unsafe
      n = complete.size
      i = 0
      while i < n
        b = ptr[i]
        if b < 0x80
          handle_char b.unsafe_chr
          i += 1
        else
          # `split_incomplete_utf8` guarantees whole sequences at the chunk
          # boundary, but a malformed lead *within* the chunk still emits U+FFFD
          # and advances one byte, matching `String`'s replacement behaviour.
          if b < 0xC0
            handle_char '�' # stray continuation byte, no lead
            i += 1
          else
            if b < 0xE0
              cp = (b & 0x1F).to_u32
              len = 2
            elsif b < 0xF0
              cp = (b & 0x0F).to_u32
              len = 3
            else
              cp = (b & 0x07).to_u32
              len = 4
            end
            ok = true
            j = 1
            while j < len
              if i + j >= n
                ok = false # truncated sequence (a following ASCII byte made the chunk "complete")
                break
              end
              cb = ptr[i + j]
              unless 0x80 <= cb <= 0xBF
                ok = false # not a continuation byte
                break
              end
              cp = (cp << 6) | (cb & 0x3F)
              j += 1
            end
            # Continuation bytes alone don't make the glyph valid: a lead >= 0xF8
            # isn't a UTF-8 lead, and the codepoint may be out of range
            # (> U+10FFFF), a UTF-16 surrogate, or an overlong encoding. A real VT
            # substitutes U+FFFD for all of these rather than emitting an invalid
            # Char, which would re-serialize as invalid UTF-8 to the host terminal.
            ok &&= b < 0xF8 &&
                   cp <= 0x10FFFF &&
                   !(0xD800_u32 <= cp <= 0xDFFF_u32) &&
                   cp >= {0x80_u32, 0x800_u32, 0x10000_u32}[len - 2]
            if ok
              handle_char cp.unsafe_chr
              i += len
            else
              handle_char '�'
              i += 1
            end
          end
        end
      end

      @on_refresh.try &.call
    end

    def feed(data : String) : Nil
      feed data.to_slice
    end

    # Splits off any trailing bytes that form an *incomplete* UTF-8 sequence so
    # they can be prepended to the next chunk. Returns {complete, leftover}.
    #
    # The leftover must be `.dup`ed, not returned as a `Slice` view: it is stashed
    # across `#feed` calls, and callers reuse one read buffer, so the next read
    # would overwrite the bytes a view pointed at. `feed` never retains
    # caller-owned memory.
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
          return {bytes[0, n - k], bytes[n - k, k].dup} if k < need
          return {bytes, Bytes.empty}
        else
          return {bytes, Bytes.empty} # ASCII byte: everything up to here is whole
        end
      end
      {bytes, Bytes.empty}
    end

    # True when the parser is inside a non-OSC escape/CSI/charset/hash sequence.
    private def in_escape_sequence? : Bool
      @state == :esc || @state == :csi || @state == :charset || @state == :hash
    end

    private def handle_char(c : Char) : Nil
      # The VT500 "anywhere" transitions. `:osc` is excluded throughout: a string
      # state runs its own ESC/terminator handling and treats controls as payload.
      #
      # ESC mid-sequence aborts the one in progress and begins a *new* escape.
      if c.ord == 0x1b && in_escape_sequence?
        @state = :esc
        return
      end
      # CAN (0x18) / SUB (0x1a) abort the sequence and produce no output.
      if (c.ord == 0x18 || c.ord == 0x1a) && @state != :ground && @state != :osc
        @state = :ground
        return
      end
      # Every other C0 control (0x00-0x1f) executes *immediately* and the
      # in-flight sequence then resumes — a control embedded in a CSI (vttest's
      # `CSI 2 <BS> C`, `CSI <CR> 2 C`, `CSI 1 <VT> A`) is not its final byte.
      if c.ord < 0x20 && in_escape_sequence?
        handle_ground c
        return
      end
      # DEL (0x7f) mid-sequence is ignored: it is neither an intermediate
      # (0x20-0x2f), a parameter (0x30-0x3f), nor a final byte, and must not
      # reach a dispatcher as a spurious final.
      if c.ord == 0x7f && in_escape_sequence?
        return
      end
      case @state
      when :ground  then handle_ground c
      when :esc     then handle_esc c
      when :csi     then handle_csi c
      when :osc     then handle_osc c
      when :charset then handle_charset c
      when :hash    then handle_hash c
      end
    end

    # Final byte of an `ESC #` sequence. Only DECALN (`ESC # 8`, the screen-
    # alignment test) is acted on; the line-size selectors (`ESC # 3`/`4`/`5`/`6`,
    # double-height/width/single-width) are swallowed with no effect, double-sized
    # lines being out of scope.
    private def handle_hash(c : Char) : Nil
      decaln if c == '8'
      @state = :ground
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
        # it rather than writing a cell. (0x80+ are printable multibyte glyphs.)
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
        @csi_intermediate = false
      when ']'
        @state = :osc
        @osc_buf.clear
        @osc_esc = false
        @osc_string = false
      when '(', ')', '*', '+'
        @charset_index = case c
                         when '(' then 0
                         when ')' then 1
                         when '*' then 2
                         else          3
                         end
        @state = :charset
      when '#'
        @state = :hash
      when ' ', '%'
        # 3-byte intermediate escapes whose final byte must be swallowed, not
        # printed: `ESC SP F/G` (S7C1T/S8C1T) and `ESC % @/G` (charset; always
        # UTF-8 here). Index -1 designates nothing, so the next byte is consumed
        # with no side effect.
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

    # Largest OSC payload (window/icon title etc.) buffered before further bytes
    # are dropped. An unterminated OSC would otherwise grow `@osc_buf` without
    # limit, retaining that capacity for the widget's lifetime. Terminator
    # scanning continues past the cap, so state recovery is unaffected; an
    # over-long title is simply truncated.
    OSC_MAX = 4096

    private def handle_osc(c : Char) : Nil
      if @osc_esc
        @osc_esc = false
        if c == '\\' # ST = ESC \
          finish_osc
          @state = :ground
          return
        end
        # A lone ESC not forming ST (ESC \) was part of the string payload;
        # restore it before handling the current byte so an OSC containing a
        # literal ESC + non-`\` isn't silently corrupted — but only for a real
        # OSC; a discarded DCS/SOS/PM/APC payload is never materialized.
        #
        # NOTE: per the strict VT500 state machine a lone ESC also aborts a
        # DCS/SOS/PM/APC string outright. That refinement was deliberately
        # NOT applied here: real-world DCS passthrough (e.g. tmux's
        # `DCS tmux; <doubled-ESC payload> ST` wrapper) relies on exactly
        # this "ESC not forming ST stays in the string" behavior — aborting
        # on the inner ESC would end the DCS early and leak the remainder of
        # the wrapped payload to the grid, regressing bug #94's own repro.
        @osc_buf << '\e' if !@osc_string && @osc_buf.bytesize < OSC_MAX
      end
      case c.ord
      when 0x07
        # BEL only terminates a *real* OSC (the xterm extension). Inside a
        # DCS/SOS/PM/APC string (`@osc_string`) it is inert payload — only
        # ST (or CAN/SUB) ends the string — so keep scanning.
        unless @osc_string
          finish_osc
          @state = :ground
        end
      when 0x18, 0x1a
        # CAN/SUB abort the string sequence from any state (VT500 "anywhere"
        # transition) and produce no output. `@osc_buf` is cleared on the
        # next OSC/DCS entry, so abandoning it here leaks nothing.
        @state = :ground
      when 0x1b then @osc_esc = true
        # A DCS/SOS/PM/APC string (`@osc_string`) is swallowed only to find its
        # ST/BEL terminator — its payload is discarded, never parsed as a title.
        # Don't append it to `@osc_buf`: otherwise a long payload (e.g. a
        # full-screen sixel image) grows the buffer, whose capacity is then
        # retained for the widget's lifetime. Still run the ESC-pending logic
        # above so ST is detected.
      else @osc_buf << c if !@osc_string && @osc_buf.bytesize < OSC_MAX
      end
    end

    # :nodoc: bytes currently buffered for the pending OSC/DCS string. Exposed
    # for tests asserting a discarded DCS/SOS/PM/APC payload is not accumulated.
    def osc_buffer_size : Int32
      @osc_buf.size.to_i
    end

    private def finish_osc : Nil
      # A DCS/SOS/PM/APC string was only swallowed for its terminator; never
      # interpret its payload as an OSC title.
      return if @osc_string
      # Only window/icon title (codes 0, 1, 2) are acted on. Parse the numeric
      # code in place from the raw buffer (like `csi_param_raw`) and materialize
      # the title `String` only when the code is a title code AND a handler is
      # installed — so OSC 7/133 (cwd/prompt marks modern shells spam) and the
      # no-listener case allocate nothing.
      handler = @on_title
      return unless handler
      ptr = @osc_buf.buffer
      size = @osc_buf.bytesize
      code = 0
      ndigits = 0
      idx = 0
      while idx < size
        b = ptr[idx]
        break if b == ';'.ord
        return unless '0'.ord <= b <= '9'.ord         # non-numeric code ⇒ not a title
        code = code * 10 + (b - '0'.ord) if code <= 9 # cap accumulation (only 0/1/2 matter; avoids overflow)
        ndigits += 1
        idx += 1
      end
      # Need at least one digit, a `;` terminator (idx < size), and a title code.
      return unless ndigits > 0 && idx < size && (code == 0 || code == 1 || code == 2)
      handler.call(String.new(ptr + idx + 1, size - idx - 1))
    end

    # Largest CSI parameter buffer retained before further parameter bytes are
    # dropped (mirrors OSC_MAX). xterm caps well under this; the exact value only
    # bounds worst-case memory on an unterminated/adversarial sequence.
    CSI_MAX = 4096

    private def handle_csi(c : Char) : Nil
      o = c.ord
      # A leading byte in 0x3c-0x3f (`<` `=` `>` `?`) is the private/intermediate
      # prefix — capture it instead of folding it into the numeric parameters.
      if @csi_prefix.nil? && @csi_buf.empty? && 0x3c <= o <= 0x3f
        @csi_prefix = c
        @csi_private = (c == '?')
        return
      end
      if o >= 0x20 && o <= 0x2f
        # Intermediate byte (space through '/'): mark the sequence and keep it
        # out of the numeric parameter buffer. `dispatch_csi` ignores any
        # sequence carrying one (see `@csi_intermediate`).
        @csi_intermediate = true
        return
      end
      if o >= 0x30 && o <= 0x3f
        # Cap the parameter buffer like OSC_MAX: an unterminated CSI (a buggy
        # child, or `ESC [` followed by megabytes of digit/`;`/`:` data) would
        # otherwise grow @csi_buf without limit, retaining that capacity for the
        # widget's lifetime. Terminator scanning below is unchanged, so state
        # recovery is unaffected — an over-long field is simply truncated.
        @csi_buf.write_byte(o.to_u8) if @csi_buf.bytesize < CSI_MAX # parameter bytes (digits, ';', ':', private markers)
        return
      end
      dispatch_csi c # final byte (0x40..0x7e)
      @state = :ground
    end

    # ───────────────────────── CSI dispatch ─────────────────────────

    # Largest value a single CSI parameter field can carry (xterm's own limit).
    # The digit-accumulating parsers below clamp each field to this, so a huge
    # but *valid* parameter (e.g. `CSI 2147483639 C`) can't make a handler's
    # arithmetic (`@x + n`, `@y + n`, `@scroll_top + row`, `@x + n - 1`)
    # overflow `Int32` — an `OverflowError` escaping `#feed` looks like EOF to
    # the reader fiber and permanently wedges the widget. Clamping (rather than
    # zeroing) matches xterm, which caps oversized parameters at 65535.
    PARAM_FIELD_MAX = 65535

    # The n-th `;`-separated parameter in `@csi_buf` (0-based), parsed in place,
    # or nil when there is no n-th field. An empty/non-numeric field reads as 0.
    # No allocation.
    private def csi_param_raw(n : Int32) : Int32?
      field = 0
      result : Int32? = nil
      # `#each_csi_param` yields the fields at indices 0, 1, 2, … in order; the
      # block inlines, so capturing the one at index `n` adds no allocation.
      each_csi_param do |v|
        result = v if field == n
        field += 1
      end
      result
    end

    # The n-th parameter, falling back to `default` when absent or zero (the VT
    # "missing/zero ⇒ default" rule).
    private def param(n : Int32, default : Int32) : Int32
      v = csi_param_raw n
      (v.nil? || v == 0) ? default : v
    end

    # The n-th parameter as a raw code (absent ⇒ 0), for the handlers that want
    # the literal value rather than the missing-⇒-default rule (`J`/`K`/`n`/`c`).
    private def param0(n : Int32) : Int32
      csi_param_raw(n) || 0
    end

    # Yields every `;`-separated parameter in turn. Always yields at least one
    # value (0 for an empty buffer).
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
          # Clamp to the field maximum (see `csi_param_raw`).
          val = Math.min(val * 10 + (b - '0'.ord), PARAM_FIELD_MAX)
        else
          bad = true
        end
        idx += 1
      end
      yield(bad ? 0 : val)
    end

    # CUU/CPL: move the cursor up *n* rows, stopping at the scroll region's top
    # margin when the cursor starts at or below it (matching xterm's `CursorUp`),
    # else at the top of the window. The clamp keeps CUU from walking out of the
    # scroll region.
    private def cursor_up(n : Int32) : Nil
      lo = @y >= @scroll_top ? @scroll_top : 0
      @y = Math.max(lo, @y - n)
    end

    # CUD/CNL: mirror of `#cursor_up` — move down *n* rows, stopping at the scroll
    # region's bottom margin (when at or above it) else the window bottom.
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
      # An intermediate byte (0x20-0x2f) makes this a different command from the
      # bare final: `CSI … $ r` (DECCARA) is not DECSTBM `r`, `CSI … SP @` (SL)
      # is not ICH `@`. None of the finals below take an intermediate, so a
      # sequence carrying one is not one we implement — ignore it rather than
      # execute the wrong command on its parameters.
      return if @csi_intermediate
      case c
      when 'A' then cursor_up(param(0, 1)); @wrap_pending = false
      # CUD ('B') and its ECMA-48 twin VPR ('e', Vertical-Position-Relative) both
      # move the cursor down; xterm maps VPR straight onto CursorDown.
      when 'B', 'e' then cursor_down(param(0, 1)); @wrap_pending = false
      # CUF ('C') and its ECMA-48 twin HPR ('a', Horizontal-Position-Relative)
      # both move the cursor right; xterm maps HPR straight onto CursorForward.
      when 'C', 'a' then @x = Math.min(@cols - 1, @x + param(0, 1)); @wrap_pending = false
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
        # SU/SD are only the *plain* `CSI Ps S` / `CSI Ps T`. A prefixed form is a
        # different command that must NOT scroll: `CSI ? Pi;Pa;Pv S` is XTSMGRAPHICS
        # (a common sixel-capability probe at startup) and `CSI > Pm T` resets xterm
        # title modes. Without the gate, `param(0, 1)` read the probe's first field
        # and scrolled the live screen (e.g. `\e[?2;1;0S` → `scroll_up` twice).
        # Same `@csi_prefix.nil?` gate as SGR/DECSTBM/SCOSC/DA.
      when 'S' then scroll_region_times(param(0, 1)) { scroll_up } if @csi_prefix.nil?   # SU
      when 'T' then scroll_region_times(param(0, 1)) { scroll_down } if @csi_prefix.nil? # SD
      when 'b' then repeat_last(param(0, 1))                                             # REP
      when 'I' then forward_tab(param(0, 1)); @wrap_pending = false                      # CHT
      when 'Z' then back_tab(param(0, 1))                                                # CBT
      when 'g' then tab_clear(param0(0))                                                 # TBC
      when 'm'
        # Only a *plain* CSI (no prefix) is SGR. A prefixed form like
        # `CSI > 4 ; 2 m` is xterm's modifyOtherKeys (emitted by vim/neovim/tmux
        # at startup), NOT a colour/style change — `apply_sgr` would misread its
        # `4` as SGR underline.
        apply_sgr if @csi_prefix.nil?
      when 'r'
        # Only a *plain* `CSI Pt ; Pb r` is DECSTBM (set scroll region). The
        # private form `CSI ? Pm r` is XTRESTORE (restore DEC private modes,
        # counterpart to the `CSI ? Pm s` XTSAVE the 's' handler ignores). Saved
        # modes aren't tracked, so the restore is a no-op, but it must NOT be
        # mistaken for DECSTBM (which would misread e.g. `CSI ? 7 r`'s `7` as a
        # top margin) — gate on the plain-CSI `@csi_prefix.nil?`.
        top = param(0, 1) - 1
        # xterm *clamps* an over-large bottom margin to the last row instead of
        # rejecting the request. Rejecting it left a stale region in place — e.g.
        # a child emitting `CSI 1;<oldrows> r` before processing SIGWINCH had its
        # DECSTBM dropped.
        bot = Math.min(param(1, @rows) - 1, @rows - 1)
        if @csi_prefix.nil? && top < bot
          @scroll_top = Math.max(0, top)
          @scroll_bottom = bot
          @x = 0
          @y = @origin_mode ? @scroll_top : 0 # DECSTBM homes the cursor
          @wrap_pending = false
        end
        # SM/RM are only the *plain* `CSI Pm h/l` (ANSI modes) or the DEC private
        # `CSI ? Pm h/l`. Any other prefix is a different command — notably
        # ANSI.SYS's `CSI = Ps h` (window mode, common in .ans art files) — and
        # must NOT be dispatched as plain SM: its parameter would be misread as
        # an ANSI mode (`CSI = 4 h` → IRM insert mode, garbling all later output).
        # Same prefix gate as SGR/DECSTBM/SCOSC/DA.
      when 'h' then set_mode true if @csi_prefix.nil? || @csi_private
      when 'l' then set_mode false if @csi_prefix.nil? || @csi_private
      when 's', 'u'
        # SCOSC/SCORC (save/restore cursor) are only the *plain* `CSI s` / `CSI u`.
        # A prefixed form must NOT move the cursor: the Kitty keyboard protocol —
        # negotiated by neovim, fish, kakoune, … at startup — pushes/pops/queries
        # its flags with `CSI > Pn u`, `CSI < Pn u`, `CSI = Pn ; Pn u` and
        # `CSI ? u`. Gating only on `@csi_private` (the `?` prefix) let `>`/`<`/`=`
        # fall through to `restore_cursor`, yanking the cursor to the last saved
        # position on a Kitty-keyboard toggle. Same `@csi_prefix.nil?` gate as SGR.
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
      when 'x'
        # DECREQTPARM (`CSI Ps x`, plain only): report terminal parameters. Only
        # Ps 0 ("please report, unsolicited allowed") and Ps 1 ("report,
        # solicited only") get a DECREPTPARM reply; the report's `sol` field is
        # Ps+2 (2 or 3). Remaining fields mirror xterm's fixed reply: no parity,
        # 8 bits, 38.4k xspeed/rspeed, clock-multiplier 1, no STP flags. Without
        # this, vttest's "Request Terminal Parameters" reports "Bad format".
        if @csi_prefix.nil?
          req = param0(0)
          respond("\e[#{req + 2};1;1;128;128;1;0x") if req == 0 || req == 1
        end
      else
        # Unimplemented final byte — ignored.
      end
    end

    private def set_mode(on : Bool) : Nil
      unless @csi_private
        # ANSI (non-private) modes. IRM (4) is the only one acted on: toggles
        # insert/replace mode (terminfo `smir`/`rmir`), consumed in `#print_char`.
        # Other standard ANSI modes (e.g. LNM 20) are ignored.
        each_csi_param { |mode| @insert_mode = on if mode == 4 }
        return
      end
      each_csi_param do |mode|
        next if set_mouse_mode(mode, on)
        case mode
        when 25       then @cursor_hidden = !on # DECTCEM
        when 47, 1047 then on ? enter_alt(false) : leave_alt(false)
        when 1048     then on ? save_cursor : restore_cursor # save/restore cursor (as DECSC/DECRC), no buffer switch
        when 1049     then on ? enter_alt(true) : leave_alt(true)
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

    # Mouse tracking (X10/1000-series) and coordinate-encoding modes; returns
    # false for non-mouse modes so `set_mode` handles them.
    private def set_mouse_mode(mode, on : Bool) : Bool
      case mode
      when    9 then @mouse_tracking = on ? 9 : 0    # X10
      when 1000 then @mouse_tracking = on ? 1000 : 0 # normal (press/release)
      when 1002 then @mouse_tracking = on ? 1002 : 0 # button-event
      when 1003 then @mouse_tracking = on ? 1003 : 0 # any-event
      # Mouse coordinate encodings: disabling one only downgrades to X10 when
      # it is the *active* one — xterm ignores a reset of a non-active
      # protocol. Without the check, a child enabling SGR (1006) and then
      # defensively resetting 1005 would drop the widget back to X10 framing
      # while the child still parses SGR (garbage keys, coords > 223 corrupt).
      when 1005 then on ? (@mouse_encoding = MouseEncoding::Utf8) : (@mouse_encoding = MouseEncoding::Normal if @mouse_encoding.utf8?)
      when 1006 then on ? (@mouse_encoding = MouseEncoding::Sgr) : (@mouse_encoding = MouseEncoding::Normal if @mouse_encoding.sgr?)
      when 1015 then on ? (@mouse_encoding = MouseEncoding::Urxvt) : (@mouse_encoding = MouseEncoding::Normal if @mouse_encoding.urxvt?)
      else           return false
      end
      true
    end

    # Whether the child has requested mouse reporting.
    def mouse_enabled? : Bool
      @mouse_tracking != 0
    end

    # ───────────────────────── alternate window ─────────────────────────

    # Parks the main buffer's DECSC save slot into `@main_saved` (on `#enter_alt`)
    # and restores it (`#leave_alt`), so the two screens keep independent slots.
    private def park_saved_slot : Nil
      @main_saved = @saved
    end

    private def unpark_saved_slot : Nil
      @saved = @main_saved
    end

    # Resets the DECSC slot to defaults (home cursor, default rendition/charset).
    # Used for the alt buffer's fresh slot and by `#full_reset`.
    private def reset_saved_slot : Nil
      @saved = SavedCursor.default(@default_attr)
    end

    # Switches to a fresh alternate page, parking the main buffer until
    # `#leave_alt`. For 1048/1049 (`save_cursor_too`) the cursor is DECSC-saved
    # into the main buffer's slot *first*, so it overwrites any earlier `ESC 7`,
    # then that slot is parked and the alt buffer gets a fresh one.
    private def enter_alt(save_cursor_too : Bool) : Nil
      return if @alt_active
      @alt_active = true
      @main_lines = @lines
      @main_ybase = @ybase
      @main_ydisp = @ydisp
      @main_scroll_top = @scroll_top
      @main_scroll_bottom = @scroll_bottom
      save_cursor if save_cursor_too
      park_saved_slot
      reset_saved_slot

      @lines = blank_page
      @ybase = 0
      @ydisp = 0
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @wrap_pending = false
    end

    # Restores the main buffer saved by `#enter_alt` (the alt page is discarded).
    # Its parked DECSC slot comes back too; for 1048/1049 the cursor is then
    # DECRC-restored from it.
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
      unpark_saved_slot
      restore_cursor if restore_cursor_too
      @wrap_pending = false
    end

    # 1-based cursor row for a CPR/DECXCPR reply. Under origin mode (DECOM) the
    # cursor row is addressed relative to the scroll region's top (see `#set_row`),
    # so the report must match — otherwise a child homing with origin coords and
    # reading the position back gets a mismatched row. Column is unaffected (no
    # left/right margins here).
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
      # Parse the bare parameter list (`@csi_buf`) directly instead of rebuilding
      # a framed `"\e[" + @csi_buf + "m"` string for `sgr_to_attr` to re-scan — one
      # fewer `String` allocation per SGR sequence.
      @cur_attr = Crysterm::Screen.sgr_params_to_attr(@csi_buf.to_slice, @cur_attr, @default_attr)
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

      # A wide glyph that STILL cannot fit in the final column — autowrap off
      # (the cursor is stuck there), or a 1-column grid (the wrap above lands
      # back on the same column) — degrades to a blank, preserving the "every
      # wide lead is followed by its CONTINUATION" invariant the renderer
      # relies on; a bare lead would paint two columns into a one-column slot
      # and spill outside the widget.
      if w == 2 && @x == @cols - 1
        c = ' '
        w = 1
      end

      line = cur_line
      if @insert_mode
        # IRM: open w cells at the cursor by shifting the tail of the line right
        # by w, dropping cells pushed past the end. Same in-place shift
        # `#insert_chars` (ICH) performs, applied per printed character — with
        # the same clipped-pair tail repair.
        shift_cells_right line, @x, w
        blank_clipped_lead_at_end line
      end
      # Repair any wide-glyph pair this write splits, matching xterm which blanks
      # the surviving half. (1) Writing onto the trailing CONTINUATION cell leaves
      # its lead at @x-1 orphaned — blank it, else the widget still treats the lead
      # as 2-wide and hides the freshly printed char. (2) After placing a w-wide
      # glyph, an old CONTINUATION at @x+w is now orphaned from its overwritten
      # lead — blank it too.
      blank_split_lead line, @x
      line[@x] = Cell.new(@cur_attr, c)
      @last_char = c # remember the placed glyph so REP ('b') can repeat it
      if w == 2 && @x + 1 < @cols
        line[@x + 1] = Cell.new(@cur_attr, CONTINUATION)
      end
      blank_split_continuation line, @x + w

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

    # REP (`CSI Pn b`): re-emit the last graphic character *n* more times, as if
    # typed again (advances the cursor, wraps normally). No-op when nothing has
    # been printed yet. Count capped at the grid area — repeating beyond a full
    # window is pointless and keeps an adversarial `CSI 99999999 b` from spinning
    # O(n), the same guard the SU/IL/ICH handlers apply.
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
      n = Math.min(n, @cols) # can't cross more tab stops than there are columns
      n.times { tab }
    end

    # CBT: move back *n* tab stops (stopping at column 0).
    private def back_tab(n : Int32) : Nil
      n = Math.min(n, @cols) # can't cross more tab stops than there are columns
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
    # region's height. SU/SD by more than the region's height leaves it fully
    # blank either way, so the surplus is a no-op, but uncapped `param.times`
    # would still iterate it — an adversarial `CSI 99999999 S` would spin O(n).
    # Same cap `#insert_lines`/`#delete_lines` apply to IL/DL.
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
        # scroll discards the displaced top line. Recycle its `Array(Cell)`
        # storage in place as the new bottom row, so the alt page never grows
        # `@lines`/`@ybase` and never exposes bogus "history" to scrollback nav.
        if @alt_active
          recycle_top_row
          return
        end
        # xterm holds the scrollback position when fresh output arrives while the
        # user is scrolled back; the view only follows the live bottom when it's
        # already there. `follow` captures "at bottom" *before* `@ybase` moves.
        follow = @ydisp == @ybase
        if @lines.size - @rows >= SCROLLBACK_LIMIT
          # Scrollback already full (the steady state while a child streams
          # output): recycle the shifted-off top line's storage as the new bottom
          # row instead of allocating a fresh `blank_line`, so this path allocates
          # nothing per scrolled line.
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
        # Recycle the scrolled-off top line's storage as the fresh blank bottom
        # row instead of allocating a new `blank_line` (mirrors recycle_top_row).
        roll_line top, bot
      end
    end

    # Recycles one line's `Array(Cell)` storage by pulling it out of `@lines` at
    # `from`, blanking it in place, and reinserting it at `to` — the shared
    # "recycle the scrolled-off line" primitive used by scroll_up/scroll_down and
    # insert_lines/delete_lines, so none of those paths allocate per line.
    private def roll_line(from : Int32, to : Int32) : Nil
      line = @lines.delete_at from
      blank_in_place line
      @lines.insert to, line
    end

    private def scroll_down : Nil
      top = @ybase + @scroll_top
      bot = @ybase + @scroll_bottom
      # Recycle the scrolled-off bottom line as the fresh blank top row.
      roll_line bot, top
    end

    private def erase_display(mode : Int32) : Nil
      # xterm's ED 0/1/2 route through ClearBelow/ClearAbove/ClearScreen, all of
      # which ResetWrap (like erase_line); a full-row wrap left pending before a
      # CSI J must not fire on the next print. ED 3 (Erase Saved Lines) only trims
      # scrollback and does NOT reset the flag in xterm, so gate it out.
      @wrap_pending = false unless mode == 3
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
        # visible page is left intact. Clearing the visible rows too (treating
        # ED 3 as ED 2 + scrollback) would make a bare `CSI 3 J` meant to trim
        # history wrongly lose on-window content. Live rows are exactly
        # `@lines[@ybase, @rows]`; just drop everything above them.
        # `Array#[start, count]` already returns a fresh array — no `.dup` needed.
        @lines = @lines[@ybase, @rows]
        @ybase = 0
        @ydisp = 0
      end
    end

    private def erase_line(mode : Int32) : Nil
      # xterm's ClearRight/ClearLeft/ClearLine all run ResetWrap: an EL after a
      # full row cancels the pending autowrap, so the next print overwrites this
      # row instead of wrapping (and possibly scrolling). Same for ICH/DCH/ECH.
      @wrap_pending = false
      case mode
      when 0 then erase_in_line @x, @cols - 1 # cursor → eol
      when 1 then erase_in_line 0, @x         # sol → cursor
      when 2 then erase_in_line 0, @cols - 1  # whole line
      end
    end

    private def clear_screen_line(yy : Int32) : Nil
      # Blank the visible row in place — visible rows are never aliased by
      # scrollback (scrollback lines live above @ybase) — instead of allocating
      # a fresh blank_line and discarding the old array.
      blank_in_place @lines[@ybase + yy]
    end

    private def erase_in_line(from : Int32, to : Int32) : Nil
      line = cur_line
      to = Math.min(to, line.size - 1)
      return unless to >= from
      # Blanking `[from, to]` can split a wide-glyph pair at either edge: a
      # CONTINUATION at *from* leaves its lead just outside the range, and a
      # lead at *to* leaves its CONTINUATION just outside. Blank the surviving
      # halves (same repair as `#print_char`), matching xterm.
      blank_split_lead line, from
      blank_split_continuation line, to + 1
      line.fill(Cell.new(erase_attr, ' '), from, to - from + 1)
    end

    # IL: open *n* blank lines at the cursor inside the scroll region, pushing the
    # rest down (lines below the region's bottom are lost). *n* is capped at the
    # lines from cursor to region bottom (a larger count just blanks the same
    # area) so an adversarial `CSI 99999 L` can't spin in O(n·height). Same cap
    # `#insert_chars`/`#delete_chars` apply on the row.
    private def insert_lines(n : Int32) : Nil
      return unless @y >= @scroll_top && @y <= @scroll_bottom
      # IL moves the active position to the line home position (ECMA-48), as
      # xterm and modern terminals do — otherwise a child doing `CSI L` then
      # printing, expecting text at the left margin, lands mid-line.
      @x = 0
      @wrap_pending = false
      n = Math.min(n, @scroll_bottom - @y + 1)
      return if n <= 0
      bot = @ybase + @scroll_bottom
      n.times do
        # Recycle the discarded bottom line as the blank line opened at the cursor.
        roll_line bot, @ybase + @y
      end
    end

    # DL: remove *n* lines at the cursor inside the scroll region, pulling the rest
    # up and backfilling the bottom with blanks. Same cap as `#insert_lines`.
    private def delete_lines(n : Int32) : Nil
      return unless @y >= @scroll_top && @y <= @scroll_bottom
      # DL, like IL, moves the active position to line home (ECMA-48).
      @x = 0
      @wrap_pending = false
      n = Math.min(n, @scroll_bottom - @y + 1)
      return if n <= 0
      bot = @ybase + @scroll_bottom
      n.times do
        # Recycle the removed line as the blank line backfilled at the bottom.
        roll_line @ybase + @y, bot
      end
    end

    # ICH: open *n* blank cells at the cursor, shifting the rest of the line right
    # (cells pushed past the end are lost). A single in-place shift, capped at
    # cells from cursor to line end, instead of *n* O(width) `Array#insert` calls
    # — keeps an adversarial `CSI 99999 @` from spinning O(n·width).
    private def insert_chars(n : Int32) : Nil
      @wrap_pending = false # xterm ResetWrap (see #erase_line)
      line = cur_line
      n = Math.min(n, line.size - @x)
      return if n <= 0
      # The gap opens at the cursor: a CONTINUATION there leaves its lead
      # orphaned on the gap's left (same repair as `#print_char`).
      blank_split_lead line, @x
      blank = Cell.new(erase_attr, ' ')
      shift_cells_right line, @x, n
      i = @x + n - 1
      while i >= @x
        line[i] = blank
        i -= 1
      end
      # Right-boundary repairs after the shift: a CONTINUATION shifted to the
      # gap's right edge lost its lead to the blank gap; and a pair straddling
      # the line end lost its CONTINUATION past it, leaving a bare wide lead in
      # the last cell.
      blank_split_continuation line, @x + n
      blank_clipped_lead_at_end line
    end

    # Blanks the wide lead at `i - 1` when the cell at *i* is its CONTINUATION —
    # the left-boundary half of the wide-glyph pair repair: an edit that
    # overwrites, blanks or shifts the cell at *i* strands the lead, which the
    # renderer would still treat as 2 columns wide (hiding the cell after it).
    # xterm blanks the surviving half; so do we. Shared by `#print_char`,
    # `#erase_in_line`, `#insert_chars` and `#delete_chars`.
    private def blank_split_lead(line : Array(Cell), i : Int32) : Nil
      if i > 0 && i < line.size && line[i].char == CONTINUATION
        line[i - 1] = Cell.new(erase_attr, ' ')
      end
    end

    # Blanks the CONTINUATION at *i* once its wide lead no longer precedes it —
    # the right-boundary half of the pair repair, for edits that overwrote,
    # blanked or shifted the lead away. A bare sentinel renders blank anyway;
    # blanking it keeps the grid honest (and its attr fresh). Out-of-range *i*
    # is a no-op so callers can pass a computed edge unguarded.
    private def blank_split_continuation(line : Array(Cell), i : Int32) : Nil
      if i < line.size && line[i].char == CONTINUATION
        line[i] = Cell.new(erase_attr, ' ')
      end
    end

    # Blanks a bare wide lead left in the line's last cell after a right-shift
    # dropped its CONTINUATION past the end. Mid-line the pair repairs keep the
    # "every wide lead is followed by its CONTINUATION" invariant, so a wide
    # lead in the last cell without one can only be a clipped pair. Shared by
    # `#insert_chars` and the IRM branch of `#print_char`.
    private def blank_clipped_lead_at_end(line : Array(Cell)) : Nil
      last = line.size - 1
      cell = line[last]
      if cell.char != CONTINUATION && ::Crysterm::Unicode.width(cell.char) == 2
        line[last] = Cell.new(erase_attr, ' ')
      end
    end

    # In-place "open `by` cells at column `from`" shift: walks the tail of `line`
    # rightward by `by`, dropping cells pushed past the end. Shared by ICH
    # (`#insert_chars`) and the IRM branch of `#print_char`. (`#delete_chars` is a
    # left-shift, intentionally separate.)
    private def shift_cells_right(line : Array(Cell), from : Int32, by : Int32) : Nil
      i = line.size - 1
      while i - by >= from
        line[i] = line[i - by]
        i -= 1
      end
    end

    # DCH: remove *n* cells at the cursor, shifting the rest of the line left and
    # backfilling the end with blanks. Same single in-place shift / cap as
    # `#insert_chars`.
    private def delete_chars(n : Int32) : Nil
      @wrap_pending = false # xterm ResetWrap (see #erase_line)
      line = cur_line
      n = Math.min(n, line.size - @x)
      return if n <= 0
      # Deletion starting on a trailing CONTINUATION leaves its lead orphaned
      # just left of the cursor (same repair as `#print_char`).
      blank_split_lead line, @x
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
      # A deletion range ending inside a pair pulls its bare CONTINUATION up to
      # the cursor column — its lead was deleted.
      blank_split_continuation line, @x
    end

    private def erase_chars(n : Int32) : Nil
      @wrap_pending = false # xterm ResetWrap (see #erase_line)
      erase_in_line @x, Math.min(@cols - 1, @x + n - 1)
    end

    private def save_cursor : Nil
      @saved = SavedCursor.new(@x, @y, @cur_attr, @g0_special, @g1_special, @gl, @origin_mode, @autowrap, @wrap_pending)
    end

    private def restore_cursor : Nil
      @x = clamp(@saved.x, 0, @cols - 1)
      @y = clamp(@saved.y, 0, @rows - 1)
      @cur_attr = @saved.attr
      @g0_special = @saved.g0_special
      @g1_special = @saved.g1_special
      @gl = @saved.gl
      @origin_mode = @saved.origin_mode
      @autowrap = @saved.autowrap
      # Re-arm the deferred wrap only when the restored cursor actually lands on
      # the last column with autowrap on (stricter than xterm's unconditional
      # restore, safer since print_char consumes @wrap_pending without re-checking
      # position).
      @wrap_pending = @saved.wrap_pending && @autowrap && @x == @cols - 1
    end

    # DECALN (`ESC # 8`): fill the entire visible screen with 'E', reset the
    # scroll region to the full window and home the cursor. The VT100 screen-
    # alignment pattern — and, more usefully here, the primitive vttest's
    # cursor-movement test builds its frame of E's from (fill the screen, then
    # erase everything but a border). Fills in place, reusing each line's storage
    # like `#blank_in_place`, so it allocates nothing.
    private def decaln : Nil
      cell = Cell.new(@cur_attr, 'E')
      @rows.times do |yy|
        refill_line @lines[@ybase + yy], cell
      end
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @x = 0
      @y = 0
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
      @mouse_encoding = MouseEncoding::Normal
      @origin_mode = false
      @bracketed_paste = false
      @focus_reporting = false
      # Drop the in-flight CSI so a partial sequence straddling the RIS can't be
      # spliced onto post-reset input. `@leftover` is deliberately NOT cleared:
      # when RIS (`ESC c`) executes mid-chunk, `@leftover` holds the chunk's
      # incomplete-UTF-8 tail — stream bytes positioned AFTER the `ESC c`, i.e.
      # legitimate post-reset input — so clearing it here would silently drop
      # them.
      @csi_buf.clear
      @csi_private = false
      @csi_prefix = nil
      @csi_intermediate = false
      # RIS also resets the DECSC/DECRC save slot (live and the parked main-buffer
      # copy) to defaults; otherwise a DECRC (`ESC 8`) after `ESC c` would restore
      # the pre-reset cursor position/attribute/charset.
      reset_saved_slot
      park_saved_slot
      reset_tab_stops
    end

    # ───────────────────────── geometry / queries ─────────────────────────

    # Pads or trims *grid* so its viewport (lines from *base* onward) holds
    # exactly *rows* lines: growing appends blank lines, shrinking drops lines
    # off the bottom (content kept at top-left). Used on resize for both the
    # live grid and the parked main buffer.
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

      # Ensure the viewport holds exactly `rows` lines, matching the per-line
      # column truncation above. Without the trim, stale rows linger past the
      # live window and a later full-window `scroll_up` would shift them back
      # into view instead of the freshly scrolled-in blank.
      fit_viewport @lines, @ybase, rows

      # When on the alt page, grow the parked main buffer's viewport too;
      # otherwise a grow-resize leaves `@main_lines` short, truncating the window
      # on `#leave_alt`.
      if ml = @main_lines
        fit_viewport ml, @main_ybase, rows
        # Reset the parked main page's scroll margins too (mirroring the active
        # page below), otherwise leaving the alt window after a resize restores a
        # stale (pre-resize) scroll region.
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

    # 0.0 (top of scrollback) .. 1.0 (bottom), matching `Widget#scroll_percent`.
    def scroll_percent : Float64
      @ybase == 0 ? 0.0 : @ydisp.to_f / @ybase
    end

    private def clamp(v : Int32, lo : Int32, hi : Int32) : Int32
      hi = lo if hi < lo
      v < lo ? lo : (v > hi ? hi : v)
    end
  end
end
