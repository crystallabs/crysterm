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

    # A single space cell carrying the current (BCE) `#erase_attr` — the erase
    # blank written to cleared/inserted cells throughout the emulator.
    private def blank_cell : Cell
      Cell.new(erase_attr, ' ')
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
      refill_line line, blank_cell
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
            # A wide-glyph pair straddling the new boundary loses only its
            # CONTINUATION to the pop, stranding a bare wide lead in the last
            # column and breaking the "every wide lead is followed by its
            # CONTINUATION" invariant. Repair it here (no-op unless the last cell
            # is a clipped lead); applies to both grids since the loop iterates
            # `@lines` and `@main_lines`.
            blank_clipped_lead_at_end line
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
