module Crysterm
  module Mixin
    # The "editable text buffer" concern, extracted from `Widget::PlainTextEdit`
    # so it can be shared without inheritance.
    #
    # Qt's `QLineEdit` is a `QWidget`, *not* a `QAbstractScrollArea` (which is
    # `QPlainTextEdit`'s base). Crysterm mirrors that: `PlainTextEdit` derives
    # `AbstractScrollArea` and includes this module, while `LineEdit` derives
    # `Input` and includes it too — getting buffer, caret, wrapping, and key
    # handling without becoming a scroll area.
    #
    # The viewport machinery this calls (`@child_base`, `_clines`,
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
        @_skip_rewind = false
      end

      # Whether finishing a read (Enter/Escape, or blur) should `rewind_focus`
      # back to the previously-focused widget. True suits one-shot inputs (a
      # prompt returning focus to its opener). A persistent form field that
      # wants to control focus itself (e.g. advance to the next field) sets
      # this false so finishing leaves focus put.
      property? rewind_on_done : Bool = true

      property __update_cursor : Proc(Nil)?

      # `getter` (not `property`): a generated `value=(String)` setter would be
      # more specific than the custom `value=` below and win overload
      # resolution for String args, bypassing set_content/_update_cursor.
      getter value : String = ""
      @_value = ""

      # Insertion-point position, as a codepoint index into `@value`
      # (`0..value.size`). Setting `value=` externally moves it to the end.
      # Movement and deletion step over whole grapheme clusters under
      # `full_unicode?`, a single codepoint otherwise.
      property cursor_pos = 0

      # The fixed end of an in-progress mouse selection (a codepoint index into
      # `@value`), or `nil` when nothing is selected. `#cursor_pos` is the other,
      # moving end. Set by the mouse-down handler installed in
      # `#_setup_text_mouse`; any keyboard interaction (`#_listener`) or external
      # `value=` drops it, since there's no keyboard-extend (Shift+arrow) support
      # yet — a plain keystroke always means "the selection is no longer live".
      property selection_anchor : Int32? = nil

      # The selected range as `[lo, hi)` codepoint indices into `@value`, or
      # `nil` when nothing is selected (no anchor, or anchor and cursor coincide
      # — a plain click with no drag).
      def selection_range : Range(Int32, Int32)?
        return nil unless anchor = @selection_anchor
        lo, hi = anchor < cursor_pos ? {anchor, cursor_pos} : {cursor_pos, anchor}
        return nil if lo == hi
        lo...hi
      end

      def has_selection? : Bool
        !!selection_range
      end

      # The currently-selected substring of `@value`, or `""` when nothing is
      # selected.
      def selected_text : String
        (r = selection_range) ? @value[r] : ""
      end

      # Drops the in-progress/completed mouse selection without moving the
      # cursor.
      def clear_selection : Nil
        @selection_anchor = nil
      end

      # Max characters the user may type, `nil` for unlimited (Qt's
      # `QLineEdit#maxLength`). Enforced only for interactive input; `value=`
      # set programmatically is not truncated.
      property max_length : Int32? = nil

      # When true, interactive editing is disabled but the cursor can still move
      # and content can be scrolled/inspected (Qt's read-only mode). `value=`
      # still works programmatically.
      property? read_only : Bool = false

      # Desired column for vertical (Up/Down) movement, as a codepoint offset
      # into the target real line. Set on the first Up/Down so that walking
      # across short lines and back preserves the original column, and cleared
      # by any other cursor movement or edit. `nil` means "no memory yet".
      @goal_col : Int32? = nil

      property _done : Proc(String?, Nil)?
      property __done : Proc(String?, Nil)?
      property __listener : Proc(Crysterm::Event::KeyPress, Nil)?

      @ev_read_input_on_focus : Crysterm::Event::Focus::Wrapper?
      @ev_enter : Crysterm::Event::KeyPress::Wrapper?
      @ev_reading : Crysterm::Event::KeyPress::Wrapper?
      @ev_done_blur : Crysterm::Event::Blur::Wrapper?

      # Seeds the text buffer from the constructor args, parking the cursor at the
      # end. Call from `initialize` *before* `super` — value must exist before
      # the base lays out its content.
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

        _setup_text_mouse
      end

      # Installs the click-to-position / drag-to-select mouse handler.
      #
      # A press moves the cursor to the clicked position and drops an anchor
      # there. It deliberately does NOT `#accept` the event: `Window#dispatch_mouse`
      # still needs to run its own default click-to-focus and emit `Event::Click`
      # (see `Window#dispatch_mouse`'s `unless me.try(&.accepted?)` gate) — this
      # handler only owns the cursor/selection side effect, not the click itself.
      #
      # A subsequent `Event::Mouse` reporting motion with a button still held
      # (`ev.button` is populated on `Move`, not just `Down`/`Up` — see
      # `Tput::Mouse::Event`) extends the selection to the new position and
      # requests a render so the highlight (`#selection_columns_for_row`) tracks
      # the drag live. Requesting the anchor lazily (`@selection_anchor ||=`)
      # tolerates a drag whose initial press this widget didn't see (e.g. focus
      # moved here without a matching `Down`).
      private def _setup_text_mouse : Nil
        on(Crysterm::Event::Mouse) do |e|
          if e.action.down?
            @goal_col = nil
            pos = position_at(e.x, e.y)
            clicks = window?.try(&.click_count) || 1
            if clicks >= 3
              # Triple-click selects the whole logical line.
              @cursor_pos = pos
              a = line_start_pos
              b = line_end_pos
              @selection_anchor = a
              @cursor_pos = b
            elsif clicks == 2
              # Double-click selects the word under the pointer (empty range —
              # i.e. just the caret — when the click is on non-word text).
              a, b = word_bounds_at(pos)
              @selection_anchor = a
              @cursor_pos = b
            else
              @cursor_pos = pos
              @selection_anchor = pos
            end
            # Capture the mouse so a drag that leaves our bounds keeps extending
            # the selection (released on button-up in `Window#dispatch_mouse`).
            window?.try &.capture_mouse(self)
            # Reflect the reposition/selection ourselves rather than relying on
            # `dispatch_mouse`'s click-to-focus render, which is skipped when
            # `focus_on_click?` is off. `render` repositions the terminal caret
            # via `_update_cursor` too. Not `#accept`ed (see method doc), so the
            # default click behavior still runs.
            request_render
          elsif e.action.move? && !e.button.none? && focused?
            # Extend the selection to the pointer. If the pointer is past the
            # vertical edge, scroll first so the drag can select off-window
            # content (`scrolled` also forces a repaint even if the mapped
            # position didn't change).
            scrolled = autoscroll_for_drag e.y
            pos = position_at(e.x, e.y)
            next if pos == @cursor_pos && @selection_anchor && !scrolled
            @goal_col = nil
            @selection_anchor ||= @cursor_pos
            @cursor_pos = pos
            request_render
            e.accept
          end
        end
      end

      # During a drag-select, scrolls one row when the pointer is past the top
      # or bottom of the visible content, so the selection can extend beyond the
      # viewport. Returns whether it scrolled. No-op for a non-scrollable widget
      # (e.g. a fitting `PlainTextEdit`, or `LineEdit`, whose `#scroll` guards on
      # `@scrollable`). Uses the same row geometry as `#position_at`.
      private def autoscroll_for_drag(y : Int32) : Bool
        return false unless @scrollable
        lpos = @lpos || _get_coords
        return false unless lpos
        max_line = (lpos.yl - lpos.yi) - iheight - 1
        raw = y - lpos.yi - itop
        before = @child_base
        if raw < 0
          scroll(-1)
        elsif raw > max_line
          scroll(1)
        end
        @child_base != before
      end

      # A text editor's "scrollable right now" is a real content-vs-height
      # overflow test, not the `@resizable` always-scrollable short-circuit it'd
      # otherwise inherit from `Input` (which made an `AsNeeded` vertical bar
      # show even when content fits, on every editor including one-line ones).
      def really_scrollable?
        content_overflows_height?
      end

      # Reserves one extra right-edge column beyond the scroll bar's so the caret
      # has somewhere to sit at the end of a full-width line.
      def content_margin_x : Int32
        super + 1
      end

      def _update_cursor(get = false, to_scroll_pos = false)
        return unless focused? # if window.focused != self

        lpos = get ? @lpos : _get_coords
        # XXX is above a bug and should be vice-versa? `get ? _get_coords : @lpos`
        return unless lpos

        display = window

        # Map the insertion point (`@cursor_pos`, an index into `@value`) onto
        # the wrapped/displayed content: the real (post-wrap) line and column.
        rl, col = cursor_rowcol

        # Place the cursor on its row within the viewport. `ensure_cursor_visible`
        # keeps the row in range already; the clamp is just a guard.
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
          # Clamp upper bound is `left + content_width`, NOT `content_width - 1`:
          # `content_margin_x` reserves the extra column at offset `content_width`
          # for the caret to sit at the END of an overflowing line. When the value
          # is wider than the viewport and the caret is at the very end,
          # `#ensure_visible_x` scrolls the base only to `full_width -
          # content_width`, leaving the caret at offset `content_width`; clamping
          # to `content_width - 1` would draw it one column too far left. A
          # fitting line is unaffected (caret stays within `0..content_width-1`).
          left = lpos.xi + ileft
          cx = (left + caret_display_column - @child_base_x).clamp(left, left + content_width)
        end

        # XXX Not sure, but this may still sometimes
        # cause problems when leaving editor.
        # E O:
        # if (cy == display.tput.cursor.y) && (cx == display.tput.cursor.x)
        #  return
        # end
        # Redundant: the logic below already no-ops if cursor is at coords.

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

      # Two-phase backward word scan from the cursor: skip the run of *separator*
      # characters immediately to the left (those the block yields true for),
      # then the run of non-separators, returning the resulting index.
      # `#word_left_pos`/`#word_start_left_pos` differ only in what counts as a
      # separator. The block is `yield`ed (inlined, no per-call closure).
      private def scan_word_left(&) : Int32
        i = @cursor_pos
        while i > 0 && (yield @value[i - 1])
          i -= 1
        end
        while i > 0 && !(yield @value[i - 1])
          i -= 1
        end
        i
      end

      # Forward counterpart of `#scan_word_left`: skip the run of separators at
      # the cursor, then the run of non-separators. Shared by `#word_right_pos`
      # and `#word_end_right_pos`.
      private def scan_word_right(&) : Int32
        i = @cursor_pos
        n = @value.size
        while i < n && (yield @value[i])
          i += 1
        end
        while i < n && !(yield @value[i])
          i += 1
        end
        i
      end

      # Start of the (whitespace-delimited) word before the cursor: skip any
      # whitespace immediately to the left, then the run of non-whitespace. Used
      # by word-wise cursor motion and `Ctrl-W` (backward kill word).
      private def word_left_pos
        scan_word_left(&.whitespace?)
      end

      # End of the (whitespace-delimited) word after the cursor: skip whitespace
      # at the cursor, then the run of non-whitespace. Used by word-wise cursor
      # motion and `Alt-D` (forward kill word).
      private def word_right_pos
        scan_word_right(&.whitespace?)
      end

      # Whether *c* is a "word constituent" for word-wise cursor motion: a
      # letter, digit, or underscore (the usual readline word set). This is a
      # finer split than the whitespace-only `word_left_pos`/`word_right_pos`
      # (which back `Ctrl-W`/`Alt-D` kills): `Ctrl-Left`/`Ctrl-Right` stop at `-`
      # and punctuation too, matching most editors' word navigation.
      private def word_char?(c : Char) : Bool
        c.alphanumeric? || c == '_'
      end

      # Start of the current/previous word, for `Ctrl-Left`: from the cursor,
      # skip any non-word separators immediately to the left, then the run of
      # word characters — landing on the leftmost word character of that word.
      private def word_start_left_pos
        scan_word_left { |c| !word_char?(c) }
      end

      # One position past the end of the current/next word, for `Ctrl-Right`:
      # from the cursor, skip any non-word separators, then the run of word
      # characters — landing just after the last word character of that word.
      private def word_end_right_pos
        scan_word_right { |c| !word_char?(c) }
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

      # Inserts `text` at the cursor and advances the cursor past it, clearing
      # the goal column as every edit does. Shared by character typing and the
      # `Ctrl-Y` yank, which differ only in where `text` comes from.
      private def insert_at_cursor(text : String) : Nil
        @goal_col = nil
        @value = @value[0...@cursor_pos] + text + @value[@cursor_pos..]
        @cursor_pos += text.size
      end

      # Removes the selected range from `@value`, parks the cursor at its start,
      # and clears the selection. Returns whether anything was deleted (`false`
      # when there was no selection), so callers can branch on "replaced a
      # selection vs. plain edit". Used by typing/Backspace/Delete/cut/paste to
      # make a selection behave as a single replaceable unit.
      private def delete_selection : Bool
        return false unless r = selection_range
        @goal_col = nil
        @value = @value[0...r.begin] + @value[r.end..]
        @cursor_pos = r.begin
        clear_selection
        true
      end

      # The `[start, end)` bounds of the word-character run touching *pos* — the
      # word double-click selects. Empty (`{pos, pos}`) when *pos* sits on a
      # non-word character (e.g. whitespace), which the caller treats as "no
      # word here". Uses the same `#word_char?` class as `Ctrl-Left`/`Ctrl-Right`.
      private def word_bounds_at(pos : Int32) : Tuple(Int32, Int32)
        lo = pos
        while lo > 0 && word_char?(@value[lo - 1])
          lo -= 1
        end
        hi = pos
        while hi < @value.size && word_char?(@value[hi])
          hi += 1
        end
        {lo, hi}
      end

      # The clipboard facade (`Application::Clipboard`) for copy/cut/paste: the
      # active window's application, or the global one as a fallback. `#text=`
      # updates the in-process mirror *and* pushes to the terminal (OSC 52);
      # `#text` reads the mirror (which may lag the real OS clipboard, but is
      # always current for a copy→paste round-trip within the app).
      private def text_clipboard
        (window?.try(&.application) || Crysterm::Application.global).clipboard
      end

      # Copies the current selection to the clipboard (mirror + terminal).
      # Returns whether there was a selection, so `Ctrl-X` only deletes when
      # something was actually cut.
      private def copy_selection : Bool
        return false unless has_selection?
        text_clipboard.text = selected_text
        true
      end

      # Inserts the clipboard's current text at the cursor, replacing any
      # selection. Reads the in-process mirror (see `#text_clipboard`), so a
      # copy→paste round-trip within the app is synchronous. Honors `max_length`
      # by truncating the pasted text to the remaining room. A single-line
      # `LineEdit` strips any pasted newlines on its next redisplay (`#value=`).
      private def paste_clipboard : Nil
        text = text_clipboard.text
        return if text.empty?
        delete_selection
        if ml = @max_length
          room = ml - @value.size
          return if room <= 0
          text = text[0, room] if text.size > room
        end
        insert_at_cursor text
      end

      # Maps `@cursor_pos` (an index into `@value`) to `{real_line, column}` in
      # the wrapped/displayed content (`@_clines`), using the fake->real line map
      # (`ftor`). Exact for the default (unaligned) text area; best-effort with
      # center/right alignment (real lines carry padding). Column is a codepoint
      # offset within the real line.
      private def cursor_rowcol : Tuple(Int32, Int32)
        c = @cursor_pos.clamp(0, @value.size)
        head = @value[0...c]
        fake_line = head.count('\n')
        nl = head.rindex('\n')
        # Column within the logical line, measured in the SAME tab-expanded
        # codepoints `process_content` lays `@_clines` out with. `@value` stores a
        # TAB as one char but the rendered line expands it to `tab_char *
        # tab_size`; counting raw codepoints here would desync the caret by
        # `tab_size - 1` per preceding TAB. With no TAB this is the original
        # `c - (nl + 1)` / `c`.
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
          # `rcol < w` keeps a mid-line position here; a boundary (`rcol == w`)
          # moves to the next wrapped piece, except on the final piece (line end).
          return {r, rcol} if rcol < w || (last && rcol <= w)
          rcol -= w
        end

        last_r = reals[-1]
        {last_r, (@_clines[last_r]? || "").size}
      end

      # Inverse of `cursor_rowcol`: maps a real (wrapped) line and a tab-expanded
      # column within it back to an index into `@value`. Used by Up/Down to land
      # the cursor on the visual row above/below at the desired column, and by
      # `#position_at` to map a mouse click to a buffer index.
      private def pos_from_rowcol(rl : Int32, col : Int32) : Int32
        rl = rl.clamp(0, Math.max(0, @_clines.size - 1))
        fake_line = @_clines.rtof[rl]? || 0

        # Expanded column within the fake (logical) line: the total expanded
        # width of preceding wrapped pieces of the same fake line, plus `col`
        # (itself expanded — see `cursor_rowcol`).
        exp_col = col
        (@_clines.ftor[fake_line]? || [rl]).each do |r|
          break if r >= rl
          exp_col += (@_clines[r]? || "").size
        end

        base, line_end = fake_line_bounds(fake_line)

        # Convert back to a raw `@value` offset: a TAB counts as one editable
        # char, not its `tab_size` rendered columns.
        (base + unexpand_col(@value[base...line_end], exp_col)).clamp(0, @value.size)
      end

      # The `@value` span (as `{start, end}` indices, half-open) of the fake
      # (logical, `\n`-delimited) line numbered *fake_line*. `@_clines.fake` is
      # TAB-expanded, so its codepoint sizes can't index raw `@value`; this walks
      # `@value`'s own newlines instead. Shared by `#pos_from_rowcol` and
      # `#position_at`.
      private def fake_line_bounds(fake_line : Int32) : Tuple(Int32, Int32)
        base = 0
        fake_line.times do
          nl = @value.index('\n', base)
          break unless nl
          base = nl + 1
        end
        {base, @value.index('\n', base) || @value.size}
      end

      # Maps an absolute screen point (as delivered by `Event::Mouse`) to the
      # nearest codepoint index into `@value` — the mouse-click counterpart of
      # `#cursor_rowcol`/`#pos_from_rowcol`, kept consistent with how
      # `#_update_cursor` actually places the caret (so clicking exactly where
      # the caret is currently drawn is a no-op). Overridden by `LineEdit`,
      # whose single visible line is a separately re-sliced tail of `@value`
      # rather than the `@_clines`/`@child_base_x` model this generic version
      # assumes. Returns the current `#cursor_pos` unchanged if the widget has
      # no on-window geometry yet (not rendered, or off-window).
      def position_at(x : Int32, y : Int32) : Int32
        lpos = _get_coords
        return cursor_pos unless lpos

        # Mirrors the row math in `#_update_cursor`: clamp to the visible
        # content rows, then add the scroll offset to get the real line index.
        max_line = (lpos.yl - lpos.yi) - iheight - 1
        line = (y - lpos.yi - itop).clamp(0, Math.max(0, max_line))
        rl = (line + @child_base).clamp(0, Math.max(0, @_clines.size - 1))

        if wrap_content?
          # `@_clines[rl]` is the actual painted (already tab-expanded) text for
          # this row — `#column_index` walks it directly by display width.
          rline = @_clines[rl]? || ""
          col = column_index(rline, x - lpos.xi - ileft)
          pos_from_rowcol(rl, col)
        else
          # Non-wrap: `@_clines[rl]` is horizontally *sliced* to the viewport
          # (see `_hslice`), so it can't be walked directly — reconstruct the
          # real line's own (tab-expanded) text from `@value` instead, exactly
          # as `#_update_cursor`'s `caret_display_column` does, and undo the
          # `@child_base_x` scroll to land back in that line's own column space.
          fake_line = @_clines.rtof[rl]? || 0
          base, line_end = fake_line_bounds(fake_line)
          raw_line = @value[base...line_end]
          expanded = raw_line.includes?('\t') ? raw_line.gsub('\t', style.tab_char * style.tab_size) : raw_line

          target = (x - lpos.xi - ileft).clamp(0, content_width) + @child_base_x
          base + unexpand_col(raw_line, column_index(expanded, target))
        end
      end

      # The codepoint index within *text* whose accumulated display width
      # (`#str_width`, wide-character aware) is nearest *target_col* — the
      # character boundary nearest a click at that pixel column. Rounds to
      # the nearest boundary (not always down), so clicking the right half of
      # a wide character lands after it. Walks whole grapheme clusters under
      # `#full_unicode?`, matching how `#cursor_prev_width`/`#cursor_next_width`
      # keep the cursor off cluster-internal codepoints elsewhere in this
      # module. Shared by both branches of `#position_at`.
      private def column_index(text : String, target_col : Int32) : Int32
        return 0 if target_col <= 0
        return target_col.clamp(0, text.size) unless full_unicode?

        acc = 0
        idx = 0
        text.each_grapheme do |g|
          s = g.to_s
          w = str_width s
          w = 1 if w <= 0 # zero-width (e.g. a lone combining mark): still one step
          return idx if acc + w / 2 > target_col
          acc += w
          idx += s.size
        end
        idx
      end

      # Codepoint count of *s* after TAB expansion (`tab_char * tab_size`, exactly
      # as `process_content` expands it) — i.e. its width in the `@_clines` column
      # units the caret math runs in. Equal to `s.size` when *s* has no TAB.
      private def expanded_width(s : String) : Int32
        return s.size unless s.includes?('\t')
        s.gsub('\t', style.tab_char * style.tab_size).size
      end

      # Inverse of `#expanded_width`: the raw codepoint offset into *line* whose
      # tab-expanded width is as large as possible without exceeding *exp_col*
      # (a caret landing inside a TAB's expansion snaps to before the TAB). A
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

      # Visual rows to move per Page Up/Down: one viewport's worth, less one row
      # of overlap for reading continuity (at least 1). "Viewport's worth" is
      # visible content rows, so a shown horizontal bar's reserved row
      # (`hscrollbar_rows`) is subtracted — as `#scroll`, `#ensure_visible`, and
      # `#clamp_child_base_to_content` do. Omitting it over-counts the page by
      # the bar's row. No-op (0) when no bar is shown.
      private def page_rows
        Math.max(1, visible_content_rows - 1)
      end

      # Scroll the *viewport* (only `@child_base`) so the caret's real (wrapped)
      # row stays on window. `@child_offset` is left at 0 — the caret is
      # `@cursor_pos`, not a scroll offset — for a single scroll model shared
      # with the attached `ScrollBar`. Delegates to `#ensure_visible` (same
      # primitive `List`/`Tree` use); returns whether the view moved, so the
      # caller can re-render (this doesn't render itself).
      #
      # Without this, the view never followed the cursor past the visible edge,
      # leaving it pinned while editing a scrolled-off line.
      private def ensure_cursor_visible : Bool
        rl, _ = cursor_rowcol
        ensure_visible rl
      end

      # Display column of the caret within its (non-wrapped) logical line — the
      # width of the line prefix up to `@cursor_pos`. Derived from `@value`, not
      # the horizontally-sliced `@_clines`, so it stays correct while scrolled.
      #
      # TABs are expanded to `tab_char * tab_size` as `process_content` does, so
      # the caret is measured against columns actually shown and stays in sync
      # with the horizontal scroll base (`@child_base_x`), measured the same way.
      private def caret_display_column : Int32
        prefix = @value[line_start_pos...@cursor_pos]
        prefix = prefix.gsub('\t', style.tab_char * style.tab_size) if prefix.includes?('\t')
        str_width prefix
      end

      # Horizontal counterpart of `#ensure_cursor_visible`: when lines don't wrap,
      # scroll the column window the minimum amount to keep the caret on window,
      # so typing past the right edge follows it. No-op while wrapping (no
      # horizontal overflow). Returns whether the view moved.
      private def ensure_cursor_visible_x : Bool
        return false if wrap_content?
        ensure_visible_x caret_display_column
      end

      # Display width of `@value[from...to]` (TAB-expanded, wide-character
      # aware) — the render-column distance between two buffer indices on the
      # same line. `#position_at`'s inverse, used to turn the selection's
      # `@value` indices into the column range `#selection_columns_for_row`
      # paints. `from` must be at or before the start of *to*'s line (both are
      # always same-line callers here, so no embedded `\n` is sliced across).
      private def rendered_column(from : Int32, to : Int32) : Int32
        s = @value[from...to]
        s = s.gsub('\t', style.tab_char * style.tab_size) if s.includes?('\t')
        str_width s
      end

      # Overrides `Widget#selection_columns_for_row` (a free no-op there): the
      # portion of `#selection_range` that falls on real (post-wrap) line *rl*,
      # as a `x - xi` column range for `Widget#_render`'s highlight pass, or
      # `nil` when the selection doesn't touch this row.
      #
      # `rl` is assumed to be `@child_base`-relative like everywhere else in
      # this module (`#position_at`, `#cursor_rowcol`) — exact for the default
      # top-aligned case `_render` uses when computing it; approximate (like
      # `#cursor_rowcol` itself) under vertical center/bottom alignment.
      #
      # Columns are shifted left by `@child_base_x` so a horizontally-scrolled
      # non-wrap view highlights the right cells (0 in wrap mode, where there is
      # no horizontal scroll). A range whose start is left of the viewport comes
      # back with a negative `begin`, which the per-cell `includes?` check in
      # `_render` handles correctly. `LineEdit` renders a re-sliced *tail* rather
      # than a `@child_base_x` slice, so it overrides this entirely.
      protected def selection_columns_for_row(rl : Int32) : Range(Int32, Int32)?
        return nil unless range = selection_range
        return nil if rl < 0 || rl >= @_clines.size

        line_start = pos_from_rowcol(rl, 0)
        line_end = pos_from_rowcol(rl, (@_clines[rl]? || "").size)

        lo = Math.max(range.begin, line_start)
        hi = Math.min(range.end, line_end)
        return nil if lo >= hi

        col_lo = rendered_column(line_start, lo) - @child_base_x
        col_hi = rendered_column(line_start, hi) - @child_base_x
        col_lo...col_hi
      end

      # Pure viewport scroll: shift `@child_base` by *offset* wrapped rows,
      # keeping `@child_offset` at 0 so `get_scroll == child_base` and the bound
      # `ScrollBar` reflects/drives the view top. Overrides the base `#scroll`
      # (whose `@child_offset` book-keeping models a moving cursor/selection,
      # here tracked separately as `@cursor_pos`). Used by the wheel and a
      # dragged scroll bar (via `#scroll_to`); the caret is untouched and may
      # scroll out of view, as in Qt's text edit.
      def scroll(offset = 1, always = false)
        return unless @scrollable && window?
        # Reserve a shown horizontal bar's row (`hscrollbar_rows`) when counting
        # visible content rows — as the base `#scroll`, `#ensure_visible`, and
        # `#clamp_child_base_to_content` do. Omitting it over-counts the viewport,
        # stopping the view one line short of the bar. No-op when no bar shown.
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
        # (any other action breaks the run via `kill_ring.interrupt` below).
        rl = Crysterm::Config.input_readline_keys
        killed = false

        if k = e.key
          # return if k == Tput::Key::Return
          if k == Tput::Key::Enter
            e.char = '\n'
            also_check_char = true
          end

          # Shift-modified movement extends the selection instead of clearing
          # it: normalize the key to its base motion and remember it was a
          # selecting move. The base motion below runs unchanged; the anchor is
          # set (once) before it and left intact after.
          extend_sel = false
          case k
          when Tput::Key::ShiftLeft     then k = Tput::Key::Left; extend_sel = true
          when Tput::Key::ShiftRight    then k = Tput::Key::Right; extend_sel = true
          when Tput::Key::ShiftUp       then k = Tput::Key::Up; extend_sel = true
          when Tput::Key::ShiftDown     then k = Tput::Key::Down; extend_sel = true
          when Tput::Key::ShiftHome     then k = Tput::Key::Home; extend_sel = true
          when Tput::Key::ShiftEnd      then k = Tput::Key::End; extend_sel = true
          when Tput::Key::ShiftPageUp   then k = Tput::Key::PageUp; extend_sel = true
          when Tput::Key::ShiftPageDown then k = Tput::Key::PageDown; extend_sel = true
          end
          # Anchor the selection at the pre-move cursor on the first selecting
          # move; subsequent ones keep extending from it.
          @selection_anchor ||= @cursor_pos if extend_sel

          # Cursor movement. Left/Right step over a whole grapheme cluster under
          # `full_unicode?` (a single codepoint otherwise). Home/End jump to the
          # start/end of the current line. Up/Down move one visual row and Page
          # Up/Down a viewport's worth, both remembering the goal column
          # (`@goal_col`) so a detour across shorter lines keeps the column.
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
          elsif !rl && k == Tput::Key::CtrlA # GUI: select all (readline off)
            @goal_col = nil
            @selection_anchor = 0
            @cursor_pos = @value.size
            extend_sel = true # keep the just-set anchor
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

          # A non-selecting movement collapses any selection; a selecting one
          # keeps its anchor so the range grows/shrinks with the cursor. Editing
          # keys (`moved == false`) manage the selection themselves below.
          clear_selection if moved && !extend_sel

          if moved
            # Follow the cursor on both axes (no-op if already visible);
            # re-render if it moved, then place the terminal cursor.
            scrolled = ensure_cursor_visible
            scrolled = ensure_cursor_visible_x || scrolled
            # A selecting move must always repaint (the highlight changed even
            # when the view didn't scroll); a plain move only when it scrolled.
            request_render if scrolled || extend_sel
            _update_cursor
          end

          # XXX
          # if @keys && CtrlE
          #  # return(Invoke editor)
          # end

          # TODO can optimize by writing directly to window buffer
          # here.
          clipboard = Crysterm::Config.input_clipboard_keys

          if k == Tput::Key::Escape
            done.try &.call nil
          elsif clipboard && k == Tput::Key::CtrlC # copy selection
            copy_selection
          elsif clipboard && !read_only? && k == Tput::Key::CtrlX # cut selection
            if copy_selection
              delete_selection
            end
          elsif clipboard && !read_only? && k == Tput::Key::CtrlV # paste at cursor
            paste_clipboard
          elsif !read_only? && (k == Tput::Key::Backspace || k == Tput::Key::CtrlH)
            # A selection deletes as one unit; otherwise remove the grapheme
            # cluster immediately before the cursor and step back over it.
            unless delete_selection
              if @cursor_pos > 0
                @goal_col = nil
                w = cursor_prev_width
                @value = @value[0...(@cursor_pos - w)] + @value[@cursor_pos..]
                @cursor_pos -= w
              end
            end
          elsif !read_only? && k == Tput::Key::Delete
            # A selection deletes as one unit; otherwise remove the grapheme
            # cluster at the cursor, leaving the cursor put.
            unless delete_selection
              if @cursor_pos < @value.size
                @goal_col = nil
                w = cursor_next_width
                @value = @value[0...@cursor_pos] + @value[(@cursor_pos + w)..]
              end
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
              insert_at_cursor text
            end
          end
        end

        if !read_only? && e.char && (!e.key || also_check_char)
          # XXX can we avoid to_s ?
          ch = e.char.to_s
          # Ignore control characters (the TAB and the Enter-newline fall
          # outside this class and are kept). Deciding this *before* touching the
          # selection means a stray control keystroke doesn't clobber it. A real
          # character typed over a selection replaces it: drop the selection
          # first, then measure `max_length` against the freed-up length so a
          # replacement in a full field still works.
          unless ch.matches? /^[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]$/
            delete_selection
            at_limit = (ml = @max_length) ? @value.size >= ml : false
            insert_at_cursor ch unless at_limit
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
        # Follow the cursor after an edit (or external `value=`), rather than
        # always jumping to the bottom — typing mid-document in a taller-than-box
        # buffer would otherwise push the just-typed character off-window.
        # Appending at the end still scrolls down since the cursor is there.
        # No render here — `value=` calls this from within its own render.
        ensure_cursor_visible
        ensure_cursor_visible_x
      end

      def value=(value = nil)
        # A non-nil argument is an external set: record it, cursor to the end.
        # `nil` means "redisplay the current value" (e.g. from `render`): keep
        # the cursor where it is, just clamped in case content changed
        # underneath (typing/deletion updates `@cursor_pos` in `_listener`).
        external = !value.nil?
        if value.nil?
          value = @value
        end

        # Record the authoritative value before the display dedup guard, so an
        # external set (e.g. clearing) is never lost when `@_value` is stale.
        @value = value
        @cursor_pos = external ? @value.size : @cursor_pos.clamp(0, @value.size)
        # An external set replaces the content out from under any selection
        # indices; a redisplay of the same content has nothing to invalidate.
        clear_selection if external
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

      # Finishes the current read, submitting the entered text. Calls the
      # done-callback directly (rather than routing Enter through `@__listener`,
      # which treats Enter as inserting a newline) so `Submit`/`read_input` fires.
      def submit
        return unless @__listener
        @_done.try &.call value
      end

      # Finishes the current read, cancelling (no value). Calls the
      # done-callback directly rather than routing Escape through `@__listener`.
      def cancel
        return unless @__listener
        @_done.try &.call nil
      end

      def clear_value
        self.value = ""
      end

      def _read_input
        if !focused?
          window.save_focus
          focus
        end

        window.grab_keys = true

        _update_cursor
        window.show_cursor

        # D O:
        # window.tput.sgr "normal"

        # Define _done_default
        @__listener = ->_listener(Crysterm::Event::KeyPress)

        # @ev_reading.try { |w| off Crysterm::Event::KeyPress, w }

        @ev_reading = on(Crysterm::Event::KeyPress) { |e|
          @__listener.try &.call e
        }

        @__done = @_done = ->_done_default(String?)

        # Store the wrapper so `__done_default` can remove it. Otherwise a new
        # Blur handler accumulates on every focus; worse, `rewind_focus` emits
        # Blur during teardown, so a stale handler would re-enter
        # `__done_default` and double-pop the focus history.
        @ev_done_blur = on(Crysterm::Event::Blur) { |e|
          # When focus moves to ANOTHER widget (Tab between form fields, click on
          # a sibling input), the user deliberately chose the new target: tear
          # down read state but do NOT `rewind_focus` (would yank focus back and
          # make Tab a no-op). Only rewind when focus is cleared entirely
          # (`e.el.nil?`) or finishing via Enter/Escape. See `#__done_default`.
          @_skip_rewind = !e.el.nil?
          @__done.try &.call nil
          @_skip_rewind = false
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

      def __done_default(data = nil)
        return unless @_reading

        # return if self(block).done?

        # Capture the `read_input(&callback)` block before it's cleared below so
        # it's actually invoked (see end of method) — needed by `Widget::Prompt`,
        # whose hide/teardown lives in the callback.
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

        window.hide_cursor
        window.grab_keys = false

        unless focused?
          window.restore_focus
        end

        if @input_on_focus && !@_skip_rewind && rewind_on_done?
          window.rewind_focus
        end

        if data
          # `data` distinguishes submit (Enter, text) from cancel (Escape/blur,
          # nil) — `value` is always non-nil so it can't tell them apart.
          emit Crysterm::Event::Submit, value
        else
          emit Crysterm::Event::Cancel, value
        end

        emit Crysterm::Event::Action, value

        # Invoke the `read_input(&callback)` block. The block keeps blessed's
        # `(err, data)` arity for API compatibility, but this event-driven read
        # path has no error source, so `err` is always nil.
        callback.try &.call(nil, data)

        nil
      end

      def _done_default(data = nil)
        __done_default data
      end
    end
  end
end
