module Crysterm
  module Mixin
    # The "editable text buffer" concern, extracted from `Widget::PlainTextEdit`
    # so it can be shared without inheritance.
    #
    # Qt's `QLineEdit` is a `QWidget`, *not* a `QAbstractScrollArea` (which is
    # `QPlainTextEdit`'s base). Crysterm mirrors that: `PlainTextEdit` derives
    # `AbstractScrollArea` and includes this module, while `LineEdit` derives
    # `Input` (the interactive intermediate) and includes it too — getting the
    # buffer, caret, wrapping, and key handling without becoming a scroll area.
    #
    # All the viewport machinery this calls (`@child_base`, `_clines`,
    # `ensure_visible`, `scroll`, `process_content`, …) lives on the base
    # `Widget` (`widget_scrolling.cr`), not on `AbstractScrollArea`, so a plain
    # `Box`/`Input` includer has it available.
    #
    # Call `setup_text_editing` from `initialize` (after `super`) to wire the
    # cursor-tracking and read handlers.
    module TextEditing
      macro included
        @_reading = false
        @input_on_focus = false
      end

      property __update_cursor : Proc(Nil)?

      # `getter` (not `property`): a generated `value=(String)` setter would be
      # more specific than the custom `value=` below and win overload
      # resolution for String args, bypassing set_content/_update_cursor.
      getter value : String = ""
      @_value = ""

      # Insertion-point position, as a codepoint index into `@value`
      # (`0..value.size`). Editing (insert/backspace/delete) and Left/Right
      # movement happen here; setting `value=` externally moves it to the end.
      # Movement and deletion step over whole grapheme clusters under
      # `full_unicode?`, and a single codepoint otherwise.
      property cursor_pos = 0

      # Maximum number of characters the user may type, or `nil` for unlimited
      # (Qt's `QLineEdit#maxLength`). Enforced only for interactive input;
      # assigning `value=` programmatically is not truncated.
      property max_length : Int32? = nil

      # When true, interactive editing is disabled but the cursor can still move
      # and the content can be scrolled/inspected (Qt's read-only mode). The
      # value can still be changed programmatically via `value=`.
      property? read_only : Bool = false

      # Desired column for vertical (Up/Down) movement, as a codepoint offset
      # into the target real line. Set on the first Up/Down so that walking
      # across short lines and back preserves the original column, and cleared
      # by any other cursor movement or edit. `nil` means "no memory yet".
      @goal_col : Int32? = nil

      property _done : Proc(String?, String?, Nil)?
      property __done : Proc(String?, String?, Nil)?
      property __listener : Proc(Crysterm::Event::KeyPress, Nil)?

      @ev_read_input_on_focus : Crysterm::Event::Focus::Wrapper?
      @ev_enter : Crysterm::Event::KeyPress::Wrapper?
      @ev_reading : Crysterm::Event::KeyPress::Wrapper?
      @ev_done_blur : Crysterm::Event::Blur::Wrapper?

      # Seeds the text buffer from the constructor args, parking the cursor at the
      # end. Call from `initialize` *before* `super` (the original ordering — the
      # value must exist before the base lays out its content).
      private def setup_text_buffer(content : String, max_length, read_only) : Nil
        @max_length = max_length
        @read_only = read_only
        @value = content
        @cursor_pos = @value.size
      end

      # Wires the cursor-following handlers and the optional Enter-to-read
      # accelerator. Call from `initialize` after `super`. `install_enter` mirrors
      # the original "only when the caller explicitly asked for `keys:`" gate.
      private def setup_text_editing(input_on_focus = false, install_enter = false) : Nil
        @__update_cursor = ->_update_cursor

        on(Crysterm::Event::Resize) do
          @__update_cursor.try &.call
        end
        on(Crysterm::Event::Move) do
          @__update_cursor.try &.call
        end

        self.input_on_focus = input_on_focus

        if !@input_on_focus && install_enter
          @ev_enter = on(Crysterm::Event::KeyPress) do |e|
            next if @_reading
            if e.key.try &.==(Tput::Key::Enter)
              next read_input
            end
          end
        end

        # XXX if mouse...
      end

      # A text editor has a fixed viewport that scrolls its content, so whether it
      # is "scrollable right now" is a real content-vs-height overflow test — not
      # the `@resizable` always-scrollable short-circuit it would otherwise
      # inherit from `Input` (`really_scrollable?` returns `@scrollable` for
      # resizable widgets, which made an `AsNeeded` vertical bar show even when the
      # content fits). Without this, every editor — even a one-line one —
      # showed a vertical scroll bar.
      def really_scrollable?
        content_overflows_height?
      end

      # A text editor reserves one extra right-edge column beyond the scroll bar's
      # so the caret has somewhere to sit at the end of a full-width line. Folded
      # into the shared content/horizontal-scroll width via `super`.
      def content_margin_x : Int32
        super + 1
      end

      def _update_cursor(get = false, to_scroll_pos = false)
        return unless focused? # if screen.focused != self

        lpos = get ? @lpos : _get_coords
        # XXX is above a bug and should be vice-versa? `get ? _get_coords : @lpos`
        return unless lpos

        display = screen

        # Map the insertion point (`@cursor_pos`, an index into `@value`) onto
        # the wrapped/displayed content: the real (post-wrap) line it lands on
        # and the column within it.
        rl, col = cursor_rowcol

        # Place the cursor on its row within the viewport. The view is kept
        # scrolled so the row is visible — `ensure_cursor_visible` follows the
        # cursor on both movement and edits — so `rl - @child_base` is normally
        # already in range; the clamp is just a guard.
        max_line = (lpos.yl - lpos.yi) - iheight - 1
        line = (rl - @child_base).clamp(0, Math.max(0, max_line))

        cy = lpos.yi + itop + line

        if wrap_content?
          rline = @_clines[rl]? || ""
          prefix = rline[0...col.clamp(0, rline.size)]
          cx = lpos.xi + ileft + str_width(prefix)
        else
          # `@_clines[rl]` is horizontally *sliced* when scrolled (see `_hslice`),
          # so derive the caret's display column from the full value line and
          # offset it by the horizontal scroll, clamped into the viewport (the
          # caret may sit at an edge when scrolled off, as in Qt's text edit).
          #
          # The clamp's upper bound is `left + content_width`, NOT
          # `content_width - 1`: `content_margin_x` reserves one extra right-edge
          # column precisely so the caret has somewhere to sit at the END of a
          # line that overflows the viewport (see `#content_margin_x`), and that
          # reserved column lives at offset `content_width` (the text occupies
          # offsets `0..content_width-1`). When the value is wider than the
          # viewport and the caret is at the very end, `#ensure_visible_x` can
          # only scroll the base to `full_width - content_width`, leaving the
          # caret at offset `content_width`; clamping to `content_width - 1` drew
          # it one column too far left — on the last visible character instead of
          # after it. A fitting line is unaffected: `#ensure_visible_x` keeps the
          # caret within `0..content_width-1` there, so the raised bound never
          # bites.
          left = lpos.xi + ileft
          cx = (left + caret_display_column - @child_base_x).clamp(left, left + content_width)
        end

        # XXX Not sure, but this may still sometimes
        # cause problems when leaving editor.
        # E O:
        # if (cy == display.tput.cursor.y) && (cx == display.tput.cursor.x)
        #  return
        # end
        # That check is redundant because the below logic also does
        # the same (no-op if cursor is already at coords.)

        if cy == display.tput.cursor.y
          if cx > display.tput.cursor.x
            display.tput.cuf(cx - display.tput.cursor.x)
          elsif cx < display.tput.cursor.x
            display.tput.cub(display.tput.cursor.x - cx)
          end
        elsif cx == display.tput.cursor.x
          if cy > display.tput.cursor.y
            display.tput.cud(cy - display.tput.cursor.y)
          elsif cy < display.tput.cursor.y
            display.tput.cuu(display.tput.cursor.y - cy)
          end
        else
          display.tput.cup(cy, cx)
        end
      end

      # Number of codepoints in the grapheme cluster immediately *before* the
      # cursor (how far Left / Backspace move). One codepoint when full-unicode
      # is off. `0` at the start of the value.
      private def cursor_prev_width
        return 0 if @cursor_pos <= 0
        return 1 unless full_unicode?
        head = @value[0...@cursor_pos]
        head.size - chop_grapheme(head).size
      end

      # Number of codepoints in the grapheme cluster immediately *at* the cursor
      # (how far Right / Delete move). One codepoint when full-unicode is off.
      # `0` at the end of the value.
      private def cursor_next_width
        return 0 if @cursor_pos >= @value.size
        return 1 unless full_unicode?
        @value[@cursor_pos..].each_grapheme.first.to_s.size
      end

      # Start of the logical line the cursor is on (just after the previous
      # newline, or 0).
      private def line_start_pos
        nl = @value.rindex('\n', @cursor_pos - 1) if @cursor_pos > 0
        nl ? nl + 1 : 0
      end

      # End of the logical line the cursor is on (just before the next newline,
      # or the end of the value).
      private def line_end_pos
        @value.index('\n', @cursor_pos) || @value.size
      end

      # Start of the (whitespace-delimited) word before the cursor: skip any
      # whitespace immediately to the left, then the run of non-whitespace. Used
      # by word-wise cursor motion and `Ctrl-W` (backward kill word).
      private def word_left_pos
        i = @cursor_pos
        while i > 0 && @value[i - 1].whitespace?
          i -= 1
        end
        while i > 0 && !@value[i - 1].whitespace?
          i -= 1
        end
        i
      end

      # End of the (whitespace-delimited) word after the cursor: skip whitespace
      # at the cursor, then the run of non-whitespace. Used by word-wise cursor
      # motion and `Alt-D` (forward kill word).
      private def word_right_pos
        i = @cursor_pos
        n = @value.size
        while i < n && @value[i].whitespace?
          i += 1
        end
        while i < n && !@value[i].whitespace?
          i += 1
        end
        i
      end

      # Whether *c* is a "word constituent" for word-wise cursor motion: a
      # letter, digit, or underscore (the usual readline word set). Separators
      # like `-`, space, and punctuation delimit words. This is a finer split
      # than the whitespace-only `word_left_pos`/`word_right_pos` (which back
      # `Ctrl-W`/`Alt-D` kills): `Ctrl-Left`/`Ctrl-Right` stop at `-` and
      # punctuation too, matching most editors' word navigation.
      private def word_char?(c : Char) : Bool
        c.alphanumeric? || c == '_'
      end

      # Start of the current/previous word, for `Ctrl-Left`: from the cursor,
      # skip any non-word separators immediately to the left, then the run of
      # word characters — landing on the leftmost word character of that word.
      private def word_start_left_pos
        i = @cursor_pos
        while i > 0 && !word_char?(@value[i - 1])
          i -= 1
        end
        while i > 0 && word_char?(@value[i - 1])
          i -= 1
        end
        i
      end

      # One position past the end of the current/next word, for `Ctrl-Right`:
      # from the cursor, skip any non-word separators, then the run of word
      # characters — landing just after the last word character of that word.
      private def word_end_right_pos
        i = @cursor_pos
        n = @value.size
        while i < n && !word_char?(@value[i])
          i += 1
        end
        while i < n && word_char?(@value[i])
          i += 1
        end
        i
      end

      # The kill ring this input uses for `Ctrl-W`/`Ctrl-U`/`Ctrl-K`/`Alt-D`
      # (kill) and `Ctrl-Y` (yank). Defaults to the shared `KillRing.default`, so
      # text killed in one field can be yanked into another; assign a fresh
      # `KillRing` to give a widget its own.
      property kill_ring : Crysterm::KillRing { Crysterm::KillRing.default }

      # Kill the text between *start* (an index into `@value` *before* the cursor)
      # and the cursor: push it onto the kill ring (prepending, so a run of
      # backward kills reads in forward order) and pull the cursor back to
      # *start*. Returns whether anything was killed (so the caller can record the
      # kill for the consecutive-kill run). Shared by `Ctrl-W` (word) and `Ctrl-U`
      # (line start), which differ only in how *start* is computed.
      private def kill_backward_to(start) : Bool
        return false unless start < @cursor_pos
        @goal_col = nil
        kill_ring.kill @value[start...@cursor_pos], prepend: true
        @value = @value[0...start] + @value[@cursor_pos..]
        @cursor_pos = start
        true
      end

      # Kill the text between the cursor and *stop* (an index into `@value`
      # *after* the cursor): push it onto the kill ring, leaving the cursor put.
      # Returns whether anything was killed. Shared by `Alt-D` (word) and `Ctrl-K`
      # (line end), which differ only in how *stop* is computed.
      private def kill_forward_to(stop) : Bool
        return false unless stop > @cursor_pos
        @goal_col = nil
        kill_ring.kill @value[@cursor_pos...stop]
        @value = @value[0...@cursor_pos] + @value[stop..]
        true
      end

      # Maps `@cursor_pos` (an index into `@value`) to `{real_line, column}` in
      # the wrapped/displayed content (`@_clines`), using the fake→real line map
      # (`ftor`). For the default (unaligned) text area this is exact; with
      # center/right alignment, where real lines carry padding, it is
      # best-effort. Column is a codepoint offset within the real line.
      private def cursor_rowcol : Tuple(Int32, Int32)
        c = @cursor_pos.clamp(0, @value.size)
        head = @value[0...c]
        fake_line = head.count('\n')
        nl = head.rindex('\n')
        # Column within the logical line, measured in the SAME tab-expanded
        # codepoints `process_content` lays `@_clines` out with. `@value` stores a
        # TAB as one char, but the rendered/wrapped line carries it as
        # `tab_char * tab_size`; counting raw `@value` codepoints here desynced the
        # caret from the text whenever a TAB sat before it (the column — and, after
        # an Up/Down through `pos_from_rowcol`, the caret itself — drifted left by
        # `tab_size - 1` per TAB, even onto the wrong line). With no TAB this is the
        # original `c - (nl + 1)` / `c`.
        col = expanded_width(nl ? @value[(nl + 1)...c] : @value[0...c])

        reals = @_clines.ftor[fake_line]?
        if reals.nil? || reals.empty?
          rl = Math.max(0, @_clines.size - 1)
          return {rl, (@_clines[rl]? || "").size}
        end

        rcol = col
        reals.each_with_index do |r, idx|
          w = (@_clines[r]? || "").size
          last = idx == reals.size - 1
          # `rcol < w` keeps a mid-line position on this real line; a boundary
          # position (`rcol == w`) moves to the start of the next wrapped piece,
          # except on the final piece, where it is the line end.
          return {r, rcol} if rcol < w || (last && rcol <= w)
          rcol -= w
        end

        last_r = reals[-1]
        {last_r, (@_clines[last_r]? || "").size}
      end

      # Inverse of `cursor_rowcol`: maps a real (wrapped) line and a tab-expanded
      # column within it back to an index into `@value`. Used by Up/Down to land
      # the cursor on the visual row above/below at the desired column.
      private def pos_from_rowcol(rl : Int32, col : Int32) : Int32
        rl = rl.clamp(0, Math.max(0, @_clines.size - 1))
        fake_line = @_clines.rtof[rl]? || 0

        # Expanded column within the fake (logical) line: this real line's start
        # (the total *expanded* width of the preceding wrapped pieces of the same
        # fake line) plus `col` (itself expanded — see `cursor_rowcol`).
        exp_col = col
        (@_clines.ftor[fake_line]? || [rl]).each do |r|
          break if r >= rl
          exp_col += (@_clines[r]? || "").size
        end

        # Start of the fake (logical) line within `@value`. `@_clines.fake` carries
        # the TAB-expanded form, so its codepoint sizes can't index the raw
        # `@value`; walk `@value`'s own newlines instead.
        base = 0
        fake_line.times do
          nl = @value.index('\n', base)
          break unless nl
          base = nl + 1
        end
        line_end = @value.index('\n', base) || @value.size

        # Convert the expanded column back to a raw `@value` offset within the
        # line, so a TAB before it counts as the single editable char it is rather
        # than its `tab_size` rendered columns.
        (base + unexpand_col(@value[base...line_end], exp_col)).clamp(0, @value.size)
      end

      # Codepoint count of *s* after TAB expansion (`tab_char * tab_size`, exactly
      # as `process_content` expands it) — i.e. its width in the `@_clines` column
      # units the caret math runs in. Equal to `s.size` when *s* has no TAB.
      private def expanded_width(s : String) : Int32
        return s.size unless s.includes?('\t')
        s.gsub('\t', style.tab_char * style.tab_size).size
      end

      # Inverse of `#expanded_width`: the raw codepoint offset into *line* whose
      # tab-expanded width is as large as possible without exceeding *exp_col* (so a
      # caret column landing inside a TAB's expansion snaps to before the TAB). A
      # plain `min(exp_col, size)` when *line* has no TAB.
      private def unexpand_col(line : String, exp_col : Int32) : Int32
        return Math.min(exp_col, line.size) unless line.includes?('\t')
        tw = style.tab_char.size * style.tab_size
        acc = 0
        i = 0
        line.each_char do |ch|
          cw = ch == '\t' ? tw : 1
          break if acc + cw > exp_col
          acc += cw
          i += 1
        end
        i
      end

      # Move the cursor by `rows` visual (wrapped) rows — negative is up, positive
      # is down — preserving the goal column. Used by Up/Down (`±1`) and Page
      # Up/Down (`±page`). The target row is clamped to the content, so a Page Up
      # near the top lands on the first row rather than doing nothing; a move that
      # would not change the row is a no-op.
      private def move_cursor_vertically(rows)
        rl, col = cursor_rowcol
        goal = (@goal_col ||= col)

        target = (rl + rows).clamp(0, Math.max(0, @_clines.size - 1))
        return if target == rl

        width = (@_clines[target]? || "").size
        @cursor_pos = pos_from_rowcol(target, goal.clamp(0, width))
      end

      # Number of visual rows to move per Page Up/Down: one viewport's worth, less
      # one row of overlap for reading continuity (at least 1). A "viewport's
      # worth" is the *visible content* rows, so a shown horizontal bar's reserved
      # bottom row (`hscrollbar_rows`) is subtracted — exactly as `#scroll`,
      # `#ensure_visible`, and `#clamp_child_base_to_content` do. Omitting it
      # over-counted the page by the bar's row, so Page Down advanced one row too
      # far and lost the overlap row whenever a horizontal bar was shown. (No-op
      # when no bar is shown — `hscrollbar_rows` is then 0.)
      private def page_rows
        Math.max(1, visible_content_rows - 1)
      end

      # Scroll the *viewport* (only `@child_base`) so the caret's real (wrapped)
      # row stays on screen, crossing the top/bottom edge as the caret moves.
      # `@child_offset` is left at 0 — the caret is `@cursor_pos`, not a scroll
      # offset — so there is a single scroll model shared with the attached
      # `ScrollBar`. Delegates to the shared `#ensure_visible` (the same primitive
      # `List`/`Tree` use); returns whether the view moved so the caller can
      # re-render. Does not render itself: the edit path calls this from within a
      # render.
      #
      # Without this, vertical movement only moved `@cursor_pos`: once the cursor
      # passed the top/bottom visible row the view never followed, leaving the
      # cursor pinned to the edge while editing a line that was scrolled off (so
      # typed text landed off-screen or painted at a stale position).
      private def ensure_cursor_visible : Bool
        rl, _ = cursor_rowcol
        ensure_visible rl
      end

      # Display column of the caret within its (non-wrapped) logical line — the
      # width of the line prefix up to `@cursor_pos`. Derived from `@value`, not
      # the horizontally-sliced `@_clines`, so it stays correct while scrolled.
      #
      # TABs are expanded to `tab_char * tab_size` exactly as `process_content`
      # does before the content is laid out and rendered, so the caret is measured
      # against the columns actually shown. Without this each TAB before the caret
      # under-counts the column by `tab_size - 1`, drifting the cursor left of the
      # text — and out of sync with the horizontal scroll base (`@child_base_x`),
      # which is measured on the same expanded content.
      private def caret_display_column : Int32
        prefix = @value[line_start_pos...@cursor_pos]
        prefix = prefix.gsub('\t', style.tab_char * style.tab_size) if prefix.includes?('\t')
        str_width prefix
      end

      # Horizontal counterpart of `#ensure_cursor_visible`: when lines don't wrap,
      # scroll the column window the minimum amount to keep the caret on screen,
      # so typing past the right edge follows it. No-op while wrapping (no
      # horizontal overflow). Returns whether the view moved.
      private def ensure_cursor_visible_x : Bool
        return false if wrap_content?
        ensure_visible_x caret_display_column
      end

      # Pure viewport scroll: shift `@child_base` by *offset* wrapped rows,
      # keeping `@child_offset` at 0 so `get_scroll == child_base` and the bound
      # `ScrollBar` reflects/drives the view top. Overrides the base `#scroll`
      # (whose `@child_offset` book-keeping models a moving cursor/selection,
      # which here is the separately-tracked `@cursor_pos`). Used by the wheel
      # and by a dragged scroll bar (via `#scroll_to`); the caret is untouched, so
      # it may scroll out of view, as in Qt's text edit.
      def scroll(offset = 1, always = false)
        return unless @scrollable && screen?
        # Reserve the row a shown horizontal bar occupies (`hscrollbar_rows`) when
        # counting visible content rows — exactly as the base `#scroll`,
        # `#ensure_visible`, and `#clamp_child_base_to_content` do. Omitting it
        # over-counts the viewport by the bar's row, so with simultaneous
        # vertical+horizontal overflow the view stops one line short and the last
        # line can't be scrolled to sit just above the bar. (No-op when no bar is
        # shown — `hscrollbar_rows` is then 0.)
        visible = visible_content_rows
        return if visible <= 0

        mark_dirty
        base = @child_base
        @child_offset = 0
        @child_base = (base + offset).clamp(0, Math.max(0, get_scroll_height - visible))
        return emit Crysterm::Event::Scroll, 0 if @child_base == base

        process_content
        clamp_child_base_to_content
        emit Crysterm::Event::Scroll, @child_base - base
      end

      def input_on_focus=(yes)
        @input_on_focus = yes

        # Always remove any current handler
        @ev_read_input_on_focus.try { |w| off Crysterm::Event::Focus, w }

        # Then add the new one if asked
        if yes
          @ev_read_input_on_focus = on(Crysterm::Event::Focus) do # |e|
            read_input
          end
        end

        # (Alternatively we could do nothing if a handler
        # is already installed and yes==true).
      end

      # ameba:disable Metrics/CyclomaticComplexity
      def _listener(e)
        done = @_done
        value = @value
        also_check_char = false
        # Emacs/readline editing keys (gated by config). `killed` records whether
        # this keystroke was a kill, so consecutive kills accumulate in the ring
        # and any other action breaks the run (`kill_ring.interrupt`, below).
        rl = Crysterm::Config.input_readline_keys
        killed = false

        if k = e.key
          # return if k == Tput::Key::Return
          if k == Tput::Key::Enter
            e.char = '\n'
            also_check_char = true
          end

          # Cursor movement. Left/Right step over a whole grapheme cluster
          # (so a base+combining mark or a wide emoji moves as one unit) under
          # `full_unicode?`, a single codepoint otherwise. Home/End jump to the
          # start/end of the current (logical) line. Up/Down move one visual
          # (wrapped) row and Page Up/Down move a viewport's worth, both
          # remembering the goal column (`@goal_col`) so that a detour across
          # shorter lines and back keeps the original column.
          moved = true
          if k == Tput::Key::Left
            @goal_col = nil
            @cursor_pos -= cursor_prev_width
          elsif k == Tput::Key::Right
            @goal_col = nil
            @cursor_pos += cursor_next_width
          elsif k == Tput::Key::Up
            move_cursor_vertically -1
          elsif k == Tput::Key::Down
            move_cursor_vertically 1
          elsif k == Tput::Key::PageUp
            move_cursor_vertically -page_rows
          elsif k == Tput::Key::PageDown
            move_cursor_vertically page_rows
          elsif k == Tput::Key::Home
            @goal_col = nil
            @cursor_pos = line_start_pos
          elsif k == Tput::Key::End
            @goal_col = nil
            @cursor_pos = line_end_pos
          elsif rl && k == Tput::Key::CtrlA # readline: line start
            @goal_col = nil
            @cursor_pos = line_start_pos
          elsif rl && k == Tput::Key::CtrlE # readline: line end
            @goal_col = nil
            @cursor_pos = line_end_pos
          elsif rl && k == Tput::Key::CtrlLeft # readline: word-char start, left
            @goal_col = nil
            @cursor_pos = word_start_left_pos
          elsif rl && k == Tput::Key::CtrlRight # readline: past word-char end, right
            @goal_col = nil
            @cursor_pos = word_end_right_pos
          elsif rl && (k == Tput::Key::AltLeft || k == Tput::Key::AltB)
            @goal_col = nil
            @cursor_pos = word_left_pos
          elsif rl && (k == Tput::Key::AltRight || k == Tput::Key::AltF)
            @goal_col = nil
            @cursor_pos = word_right_pos
          else
            moved = false
          end

          if moved
            # Scroll the viewport to follow the cursor on both axes (no-op when
            # already visible); re-render if it moved, then place the terminal
            # cursor at its new position.
            scrolled = ensure_cursor_visible
            scrolled = ensure_cursor_visible_x || scrolled
            request_render if scrolled
            _update_cursor
          end

          # XXX
          # if @keys && CtrlE
          #  # return(Invoke editor)
          # end

          # TODO can optimize by writing directly to screen buffer
          # here.
          if k == Tput::Key::Escape
            done.try &.call nil, nil
          elsif !read_only? && (k == Tput::Key::Backspace || k == Tput::Key::CtrlH)
            # Delete the grapheme cluster (base + combining marks, wide emoji, …)
            # immediately before the cursor, then move the cursor back over it.
            if @cursor_pos > 0
              @goal_col = nil
              w = cursor_prev_width
              @value = @value[0...(@cursor_pos - w)] + @value[@cursor_pos..]
              @cursor_pos -= w
            end
          elsif !read_only? && k == Tput::Key::Delete
            # Delete the grapheme cluster at the cursor; the cursor stays put.
            if @cursor_pos < @value.size
              @goal_col = nil
              w = cursor_next_width
              @value = @value[0...@cursor_pos] + @value[(@cursor_pos + w)..]
            end
          elsif rl && !read_only? && k == Tput::Key::CtrlW # kill word before cursor
            killed = kill_backward_to word_left_pos
          elsif rl && !read_only? && k == Tput::Key::AltD # kill word after cursor
            killed = kill_forward_to word_right_pos
          elsif rl && !read_only? && k == Tput::Key::CtrlU # kill to line start
            killed = kill_backward_to line_start_pos
          elsif rl && !read_only? && k == Tput::Key::CtrlK # kill to line end
            stop = line_end_pos
            # At the end of a line, kill the newline itself (join with the next).
            stop += 1 if stop == @cursor_pos && @cursor_pos < @value.size
            killed = kill_forward_to stop
          elsif rl && !read_only? && k == Tput::Key::CtrlY # yank
            if text = kill_ring.yank
              @goal_col = nil
              @value = @value[0...@cursor_pos] + text + @value[@cursor_pos..]
              @cursor_pos += text.size
            end
          end
        end

        if !read_only? && e.char && (!e.key || also_check_char)
          # XXX can we avoid to_s ?
          # Enforce the character limit (Qt `maxLength`); a newline produced by
          # Enter (`also_check_char`) counts toward it too.
          at_limit = (ml = @max_length) ? @value.size >= ml : false
          unless at_limit || e.char.to_s.matches? /^[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]$/
            # Insert the typed character at the cursor (not just at the end),
            # then advance the cursor past it.
            @goal_col = nil
            ch = e.char.to_s
            @value = @value[0...@cursor_pos] + ch + @value[@cursor_pos..]
            @cursor_pos += ch.size
          end
        end

        if @value != value
          emit Crysterm::Event::TextChange, @value
          request_render
        end

        # Any keystroke that wasn't itself a kill ends the consecutive-kill run,
        # so the next kill starts a fresh ring entry (emacs semantics).
        kill_ring.interrupt if rl && !killed
      end

      def _type_scroll
        # Follow the cursor after an edit (or an external `value=`), rather than
        # always jumping to the bottom: when typing in the middle of a document
        # taller than the box, snapping to the end would push the just-typed
        # character off-screen. Appending at the end still scrolls down, because
        # the cursor is then on the last line. No render here — `value=` calls
        # this from within the widget's own render.
        ensure_cursor_visible
        ensure_cursor_visible_x
      end

      def value=(value = nil)
        # A non-nil argument is an external set: record it and move the cursor
        # to the end. `nil` means "redisplay the current value" (e.g. from
        # `render`): keep the cursor where it is, only clamping it in case the
        # content changed underneath us (typing/deletion updates `@cursor_pos`
        # itself in `_listener`).
        external = !value.nil?
        if value.nil?
          value = @value
        end

        # Always record the authoritative value before the display dedup guard,
        # so an external set (e.g. clearing) is never lost when `@_value` is stale.
        @value = value
        @cursor_pos = external ? @value.size : @cursor_pos.clamp(0, @value.size)
        return if @_value == value

        @_value = value
        set_content value
        _type_scroll
        _update_cursor
      end

      def render
        self.value = nil
        super # OR _render
      end

      # Finishes the current read, submitting the entered text. Previously this
      # routed an Enter keypress through `@__listener`, but the editor listener
      # treats Enter as inserting a literal newline — so `submit` *inserted a
      # newline* instead of completing. Call the done-callback directly with the
      # value so the `Submit` (and `read_input`) path fires.
      def submit
        return unless @__listener
        @_done.try &.call nil, value
      end

      # Finishes the current read, cancelling (no value). Calls the
      # done-callback directly rather than routing Escape through `@__listener`.
      def cancel
        return unless @__listener
        @_done.try &.call nil, nil
      end

      def clear_value
        self.value = ""
      end

      def _read_input
        if !focused?
          screen.save_focus
          focus
        end

        screen.grab_keys = true

        _update_cursor
        screen.show_cursor

        # D O:
        # screen.tput.sgr "normal"

        # Define _done_default
        @__listener = ->_listener(Crysterm::Event::KeyPress)

        # @ev_reading.try { |w| off Crysterm::Event::KeyPress, w }

        @ev_reading = on(Crysterm::Event::KeyPress) { |e|
          @__listener.try &.call e
        }

        @__done = @_done = ->_done_default(String?, String?)

        # Store the wrapper so `__done_default` can remove it. Otherwise a new
        # Blur handler is added on every focus and they accumulate; worse,
        # `rewind_focus` emits Blur during teardown, so a stale handler would
        # re-enter `__done_default` and double-pop the focus history.
        @ev_done_blur = on(Crysterm::Event::Blur) {
          @__done.try &.call nil, nil
        }
      end

      def read_input(&callback : Proc(String?, String?, Nil))
        return if @_reading
        @_reading = true
        @_callback = callback
        _read_input
      end

      def read_input
        return if @_reading
        @_reading = true
        @_callback = nil
        _read_input
      end

      def __done_default(err = nil, data = nil)
        return unless @_reading

        # return if self(block).done?

        # Capture the `read_input(&callback)` block before it is cleared below,
        # so it can actually be invoked (see end of method). Previously it was
        # cleared without ever being called, so the block form silently did
        # nothing — which broke `Widget::Prompt`, whose hide/teardown lives in it.
        callback = @_callback

        @ev_reading.try { |w| off Crysterm::Event::KeyPress, w }
        @ev_reading = nil
        @_reading = false

        @_callback = nil
        @_done = nil
        # XXX off Crysterm::Event::KeyPress, @__listener.wrapper
        @__listener = nil
        @ev_done_blur.try { |w| off Crysterm::Event::Blur, w }
        @ev_done_blur = nil
        @__done = nil

        screen.hide_cursor
        screen.grab_keys = false

        unless focused?
          screen.restore_focus
        end

        if @input_on_focus
          screen.rewind_focus
        end

        # damn
        return if err == "stop"

        if err
          raise err # XXX just temporary
        elsif data
          # `data` is the value passed to the done-callback: the text on
          # submit (Enter), and nil on cancel (Escape) or blur. The `value`
          # property is always a non-nil String, so it can't be used to tell
          # the two apart.
          emit Crysterm::Event::Submit, value
        else
          emit Crysterm::Event::Cancel, value
        end

        emit Crysterm::Event::Action, value

        # Invoke the block passed to `read_input(&callback)` with `(err, data)`
        # (data is the entered value on submit, nil on cancel/blur).
        callback.try &.call(err, data)

        nil
      end

      def _done_default(err = nil, data = nil)
        __done_default err, data
      end
    end
  end
end
