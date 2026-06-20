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
  # cursor save/restore, title (OSC 0/2), and the basic device-status/attributes
  # replies. It intentionally does NOT implement: the alternate screen buffer as
  # a separate page (1049/47 are accepted but ignored), double-width/height
  # lines, full charset designation, or mouse-mode tracking (the *widget*
  # forwards mouse separately). These are noted at each site and are easy to add
  # later without changing the public surface.
  #
  # The SGR ('m') handler deliberately reuses `Crysterm::Screen.attr2code`, the
  # same well-tested converter the rest of Crysterm uses, so 16/256/truecolour
  # all behave identically to native content.
  class TerminalEmulator
    # One grid cell. A *class* (not a struct) so that in-place edits via
    # `line[x].attr = …` write through — an `Array(struct)` would only mutate a
    # copy. Allocation volume is modest (one per occupied cell) and can be
    # optimised into parallel arrays later if it ever matters.
    class Cell
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

    # Parser state.
    @state : Symbol = :ground
    @csi_buf : String = ""
    @csi_private : Bool = false
    @osc_buf : String = ""
    @osc_esc : Bool = false

    # Trailing incomplete UTF-8 bytes held back between `#feed` calls.
    @leftover : Bytes = Bytes.empty

    def initialize(@cols : Int32, @rows : Int32, default_attr : Int64)
      @cols = 1 if @cols < 1
      @rows = 1 if @rows < 1
      @default_attr = default_attr
      @cur_attr = default_attr
      @saved_attr = default_attr
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
      when :charset then @state = :ground # consume one charset-designator byte
      end
    end

    private def handle_ground(c : Char) : Nil
      case c.ord
      when 0x1b then @state = :esc
      when 0x07 then @on_bell.try &.call
      when 0x08 then backspace
      when 0x09 then tab
      when 0x0a, 0x0b, 0x0c then line_feed
      when 0x0d then @x = 0; @wrap_pending = false
      when 0x0e, 0x0f then # SO/SI charset shifts — ignored
      else
        print_char c if c.ord >= 0x20
      end
    end

    private def handle_esc(c : Char) : Nil
      case c
      when '['
        @state = :csi
        @csi_buf = ""
        @csi_private = false
      when ']'
        @state = :osc
        @osc_buf = ""
        @osc_esc = false
      when '(', ')', '*', '+'
        @state = :charset
      when 'P', 'X', '^', '_'
        # DCS/SOS/PM/APC string — swallow like an OSC (until ST/BEL).
        @state = :osc
        @osc_buf = ""
        @osc_esc = false
      when '7' then save_cursor; @state = :ground
      when '8' then restore_cursor; @state = :ground
      when 'M' then reverse_index; @state = :ground   # RI
      when 'D' then line_feed; @state = :ground        # IND
      when 'E' then @x = 0; line_feed; @state = :ground # NEL
      when 'c' then full_reset; @state = :ground       # RIS
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
      else           @osc_buf += c
      end
    end

    private def finish_osc : Nil
      # Only window/icon title (codes 0, 1, 2) are acted on.
      if idx = @osc_buf.index(';')
        code = @osc_buf[0, idx]
        text = @osc_buf[(idx + 1)..]
        @on_title.try(&.call(text)) if code == "0" || code == "1" || code == "2"
      end
    end

    private def handle_csi(c : Char) : Nil
      o = c.ord
      if c == '?' && @csi_buf.empty?
        @csi_private = true
        return
      end
      if o >= 0x20 && o <= 0x3f
        @csi_buf += c # parameter / intermediate bytes
        return
      end
      dispatch_csi c # final byte (0x40..0x7e)
      @state = :ground
    end

    # ───────────────────────── CSI dispatch ─────────────────────────

    private def params : Array(Int32)
      @csi_buf.split(';').map { |s| s.empty? ? 0 : (s.to_i? || 0) }
    end

    private def param(list : Array(Int32), n : Int32, default : Int32) : Int32
      v = list[n]?
      (v.nil? || v == 0) ? default : v
    end

    private def dispatch_csi(c : Char) : Nil
      p = params
      case c
      when 'A' then @y = Math.max(0, @y - param(p, 0, 1)); @wrap_pending = false
      when 'B' then @y = Math.min(@rows - 1, @y + param(p, 0, 1)); @wrap_pending = false
      when 'C' then @x = Math.min(@cols - 1, @x + param(p, 0, 1)); @wrap_pending = false
      when 'D' then @x = Math.max(0, @x - param(p, 0, 1)); @wrap_pending = false
      when 'E' then @x = 0; @y = Math.min(@rows - 1, @y + param(p, 0, 1))
      when 'F' then @x = 0; @y = Math.max(0, @y - param(p, 0, 1))
      when 'G', '`' then @x = clamp(param(p, 0, 1) - 1, 0, @cols - 1); @wrap_pending = false
      when 'd' then @y = clamp(param(p, 0, 1) - 1, 0, @rows - 1)
      when 'H', 'f'
        @y = clamp(param(p, 0, 1) - 1, 0, @rows - 1)
        @x = clamp(param(p, 1, 1) - 1, 0, @cols - 1)
        @wrap_pending = false
      when 'J' then erase_display(p[0]? || 0)
      when 'K' then erase_line(p[0]? || 0)
      when 'L' then insert_lines(param(p, 0, 1))
      when 'M' then delete_lines(param(p, 0, 1))
      when 'P' then delete_chars(param(p, 0, 1))
      when '@' then insert_chars(param(p, 0, 1))
      when 'X' then erase_chars(param(p, 0, 1))
      when 'S' then param(p, 0, 1).times { scroll_up }
      when 'T' then param(p, 0, 1).times { scroll_down }
      when 'm' then apply_sgr
      when 'r'
        top = param(p, 0, 1) - 1
        bot = param(p, 1, @rows) - 1
        if top < bot && bot <= @rows - 1
          @scroll_top = Math.max(0, top)
          @scroll_bottom = Math.min(@rows - 1, bot)
          @x = 0
          @y = 0
        end
      when 'h' then set_mode true, p
      when 'l' then set_mode false, p
      when 's' then save_cursor unless @csi_private
      when 'u' then restore_cursor unless @csi_private
      when 'n' then device_status(p[0]? || 0)
      when 'c' then respond("\e[?6c") if (p[0]? || 0) == 0 # VT102 Device Attributes
      else
        # Unimplemented final byte — ignored.
      end
    end

    private def set_mode(on : Bool, p : Array(Int32)) : Nil
      return unless @csi_private
      p.each do |mode|
        case mode
        when 25 then @cursor_hidden = !on # DECTCEM
        else
          # 1049/47/1047 (alt screen), 1000+ (mouse), 2004 (bracketed paste),
          # 1 (DECCKM) … accepted and ignored for now.
        end
      end
    end

    private def device_status(code : Int32) : Nil
      case code
      when 5 then respond("\e[0n")                          # "OK"
      when 6 then respond("\e[#{@y + 1};#{@x + 1}R")        # cursor position
      end
    end

    private def respond(s : String) : Nil
      @output.try &.print(s)
      @output.try &.flush
    end

    private def apply_sgr : Nil
      seq = "\e[" + @csi_buf + "m"
      @cur_attr = Crysterm::Screen.attr2code(seq, @cur_attr, @default_attr)
    end

    # ───────────────────────── editing primitives ─────────────────────────

    private def print_char(c : Char) : Nil
      if @wrap_pending
        @x = 0
        line_feed
        @wrap_pending = false
      end
      cell = cur_line[@x]
      cell.attr = @cur_attr
      cell.char = c
      if @x >= @cols - 1
        @x = @cols - 1
        @wrap_pending = true
      else
        @x += 1
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
        @lines << blank_line
        @ybase += 1
        if @lines.size - @rows > SCROLLBACK_LIMIT
          @lines.shift
          @ybase -= 1
        end
        @ydisp = @ybase
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
      when 1 then erase_in_line 0, @x          # sol → cursor
      when 2 then erase_in_line 0, @cols - 1   # whole line
      end
    end

    private def clear_screen_line(yy : Int32) : Nil
      @lines[@ybase + yy] = blank_line
    end

    private def erase_in_line(from : Int32, to : Int32) : Nil
      line = cur_line
      ea = erase_attr
      (from..to).each do |xx|
        next unless cell = line[xx]?
        cell.attr = ea
        cell.char = ' '
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
      @lines.each do |line|
        if line.size < cols
          (cols - line.size).times { line.push Cell.new(ea, ' ') }
        elsif line.size > cols
          line.pop(line.size - cols)
        end
      end

      # Ensure the viewport holds exactly `rows` lines.
      screen_lines = @lines.size - @ybase
      if screen_lines < rows
        (rows - screen_lines).times { @lines << blank_line }
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

    def scroll_height : Int32
      @rows - 1
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
