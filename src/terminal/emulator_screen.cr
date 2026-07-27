module Crysterm
  class TerminalEmulator
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
      # a framed `"\e[" + @csi_buf + "m"` string for the SGR parser to re-scan — one
      # fewer `String` allocation per SGR sequence.
      @cur_attr = Crysterm::SGR.params_to_attr(@csi_buf.to_slice, @cur_attr, @default_attr)
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
      line.fill(blank_cell, from, to - from + 1)
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
      blank = blank_cell
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
        line[i - 1] = blank_cell
      end
    end

    # Blanks the CONTINUATION at *i* once its wide lead no longer precedes it —
    # the right-boundary half of the pair repair, for edits that overwrote,
    # blanked or shifted the lead away. A bare sentinel renders blank anyway;
    # blanking it keeps the grid honest (and its attr fresh). Out-of-range *i*
    # is a no-op so callers can pass a computed edge unguarded.
    private def blank_split_continuation(line : Array(Cell), i : Int32) : Nil
      if i < line.size && line[i].char == CONTINUATION
        line[i] = blank_cell
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
        line[last] = blank_cell
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
      blank = blank_cell
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
  end
end
