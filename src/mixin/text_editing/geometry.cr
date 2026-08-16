module Crysterm
  module Mixin
    module TextEditing
      # Repositions the hardware caret to the insertion point. Two callers, two
      # geometry sources:
      #
      # * `rendered: false` (default) — an interactive keystroke handler, running
      #   *before* the next frame, when `@lpos` still holds the PREVIOUS frame's
      #   box (stale after a content change). Recompute the box fresh via
      #   `#coords` so the caret lands at the new position without waiting for a
      #   render.
      # * `rendered: true` — the post-render pass (inside `Window#repaint`'s frame, after
      #   `flush_frame`), when `@lpos` was just written by that render and is the
      #   authoritative painted box. Reuse it rather than recomputing.
      #
      # (The two are NOT interchangeable: using `@lpos` in the interactive path
      # would place the caret against a stale box.)
      def _update_cursor(rendered = false)
        return unless focused? # if window.focused != self

        lpos = rendered ? @lpos : coords
        return unless lpos

        display = window

        # Map the insertion point (`@cursor_pos`, a buffer position) onto the
        # wrapped/displayed content: the real (post-wrap) line and column.
        # `@_pending_rowcol` carries the mapping `_listener` already computed for
        # `ensure_cursor_visible`, so a movement keystroke runs `cursor_rowcol`
        # once, not twice.
        rl, col = @_pending_rowcol || cursor_rowcol

        # Place the cursor on its row within the viewport. `ensure_cursor_visible`
        # keeps the row in range already; the clamp is just a guard.
        max_line = max_content_row(lpos)
        # Use the clip-aware row origin the base renderer uses (`lpos.base`), not
        # `@child_base`: when an ancestor clips the top, `coords` accumulates the
        # clipped row count into `coords.base`, so `lpos.base == @child_base +
        # clipped`. Mapping through `@child_base` alone places the caret `clipped`
        # rows off.
        line = (rl - lpos.base).clamp(0, Math.max(0, max_line))

        cy = lpos.yi + itop + line

        if wrap_content?
          rline = @wrapped_lines[rl]? || ""
          c = col.clamp(0, rline.size)
          # `@wrapped_lines[rl]` is the already-tab-expanded display piece, so in the
          # legacy (non-full-unicode) width path its `[0, c)` width IS `c` — no
          # substring needs to be built to measure a length already in hand.
          w = full_unicode? ? str_width(rline[0...c]) : c
          cx = lpos.xi + ileft + row_text_x_offset(rl) + w
        else
          # `@wrapped_lines[rl]` is horizontally *sliced* when scrolled (see `_hslice`),
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
          cx = (left + row_text_x_offset(rl) + caret_display_column - @child_base_x).clamp(left, left + content_width)
        end

        move_terminal_caret display, cx, cy
      end

      # Emits the minimal terminal caret move from the terminal's current cursor
      # to `(cx, cy)`: a relative `cuf`/`cub`/`cud`/`cuu` when the caret shares a
      # row or column with it (a no-op when already there), else an absolute `cup`.
      private def move_terminal_caret(display, cx, cy)
        # `cy` is a surface row; the terminal's tracked cursor (`tput.cursor.y`)
        # is physical. In an inline window they differ by the render offset —
        # add it so the hardware caret lands in the rendered region (no-op when
        # the offset is 0).
        cy += display.render_row_offset
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

      # Codepoint count of a grapheme cluster; the `@cluster`-reading
      # implementation lives in `Unicode.cluster_size`, next to the width
      # reader that shares (and pins) the same stdlib-internal layout.
      private def grapheme_cps(g : String::Grapheme) : Int32
        Unicode.cluster_size g
      end

      # Number of codepoints in the grapheme cluster immediately *before* the
      # cursor (how far Left / Backspace move). One codepoint when full-unicode
      # is off. `0` at the start of the value.
      #
      # Only the LAST cluster before the cursor is needed, so scan back over a
      # bounded window (widened only for the pathological cluster longer than the
      # window) rather than materializing and grapheme-walking the whole prefix.
      private def cursor_prev_width
        return 0 if @cursor_pos <= 0
        return 1 unless full_unicode?
        k = 16
        loop do
          start = Math.max(0, @cursor_pos - k)
          window = buf_slice(start, @cursor_pos)
          last = nil
          window.each_grapheme { |g| last = g }
          size = last ? grapheme_cps(last) : 0
          # `size < window.size` means the last cluster began after the window
          # start, so it's whole; at buffer start there's nothing more to see.
          return size if start == 0 || size < window.size
          k *= 2
        end
      end

      # Number of codepoints in the grapheme cluster immediately *at* the cursor
      # (how far Right / Delete move). One codepoint when full-unicode is off.
      # `0` at the end of the value.
      #
      # Only the FIRST cluster at the cursor is needed, so read it from a bounded
      # window (widened only for a cluster longer than the window) rather than
      # slicing the entire remaining buffer.
      private def cursor_next_width
        return 0 if @cursor_pos >= buf_size
        return 1 unless full_unicode?
        n = buf_size
        k = 16
        loop do
          stop = Math.min(@cursor_pos + k, n)
          g = buf_slice(@cursor_pos, stop).each_grapheme.first
          size = grapheme_cps(g)
          # The cluster is whole when it ended before the window edge, or the
          # window already reached the buffer end.
          return size if stop == n || @cursor_pos + size < stop
          k *= 2
        end
      end

      # Start of the logical line the cursor is on (just after the previous
      # newline, or 0).
      private def line_start_pos
        nl = buf_rindex('\n', @cursor_pos - 1) if @cursor_pos > 0
        nl ? nl + 1 : 0
      end

      # End of the logical line the cursor is on (just before the next newline,
      # or the end of the value).
      private def line_end_pos
        buf_index('\n', @cursor_pos) || buf_size
      end

      # Two-phase backward word scan from the cursor: skip the run of *separator*
      # characters immediately to the left (those the block yields true for), then
      # the run of non-separators, returning the resulting index. The predicate is
      # `yield`ed the character, so it inlines with no per-call closure.
      private def scan_word_left(&) : Int32
        TextDocument.scan_word_left(@cursor_pos) { |i| yield buf_char(i) }
      end

      # Forward counterpart of `#scan_word_left`: skip the run of separators at the
      # cursor, then the run of non-separators.
      private def scan_word_right(&) : Int32
        TextDocument.scan_word_right(@cursor_pos, buf_size) { |i| yield buf_char(i) }
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

      # Whether *c* is a "word constituent" for word-wise cursor motion: a letter,
      # digit, or underscore (the usual readline word set). A finer split than the
      # whitespace-only `word_left_pos`/`word_right_pos` backing the
      # `Ctrl-W`/`Alt-D` kills: `Ctrl-Left`/`Ctrl-Right` stop at `-` and
      # punctuation too, matching most editors' word navigation.
      private def word_char?(c : Char) : Bool
        TextDocument.word_char?(c)
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

      # Kill the text between *start* (a buffer position *before* the cursor)
      # and the cursor: push it onto the kill ring (prepending, so a run of
      # backward kills reads in forward order) and pull the cursor back to *start*.
      # Returns whether anything was killed, so the caller can record the kill for
      # the consecutive-kill run.
      private def kill_backward_to(start) : Bool
        return false unless kill_range(start, @cursor_pos, prepend: true)
        # Only on an actual kill: the text ahead of *start* has moved onto it.
        @cursor_pos = start
        true
      end

      # Kill the text between the cursor and *stop* (a buffer position *after* the
      # cursor): push it onto the kill ring, leaving the cursor put. Returns
      # whether anything was killed.
      private def kill_forward_to(stop) : Bool
        kill_range(@cursor_pos, stop, prepend: false)
      end

      # Shared body of the two directional kills: ring the `lo...hi` text, delete
      # it, drop the goal column and the selection. Returns whether the range was
      # non-empty (nothing happens when it wasn't).
      #
      # *prepend* is the kill ring's accumulation direction for a consecutive-kill
      # run, and belongs to the *direction*, not to the range: only backward kills
      # prepend, so `C-w C-w` reads back in forward order (emacs semantics).
      #
      # The slice must be read *before* the delete, and callers must not move the
      # caret until this has returned.
      private def kill_range(lo : Int32, hi : Int32, prepend : Bool) : Bool
        return false unless lo < hi
        @goal_col = nil
        kill_ring.kill buf_slice(lo, hi), prepend: prepend
        buf_delete(lo, hi)
        clear_selection
        true
      end

      # Inserts `text` at the cursor and advances the cursor past it, clearing the
      # goal column as every edit does.
      private def insert_at_cursor(text : String) : Nil
        @goal_col = nil
        buf_insert(@cursor_pos, text)
        @cursor_pos += text.size
      end

      # Removes the selected range from the buffer, parks the cursor at its start,
      # and clears the selection. Returns whether anything was deleted (`false` when
      # there was no selection), so callers can branch on "replaced a selection vs.
      # plain edit".
      private def delete_selection : Bool
        # Even when there's no live range (collapsed selection, anchor == cursor),
        # drop the anchor: a stale collapsed anchor would otherwise resurrect as a
        # phantom 1-char selection once the next edit moves the cursor off it,
        # swallowing the following keystroke.
        unless r = selection_range
          clear_selection
          return false
        end
        @goal_col = nil
        buf_delete(r.begin, r.end)
        @cursor_pos = r.begin
        clear_selection
        true
      end

      # The `[start, end)` bounds of the word-character run touching *pos* — the
      # word double-click selects. Empty (`{pos, pos}`) when *pos* sits on a
      # non-word character (e.g. whitespace), which the caller treats as "no word
      # here".
      private def word_bounds_at(pos : Int32) : Tuple(Int32, Int32)
        TextDocument.word_run_at(pos, buf_size) { |i| word_char?(buf_char(i)) }
      end

      # The clipboard facade (`Application::Clipboard`) for copy/cut/paste: the
      # active window's application, or the global one as a fallback. `#text=`
      # updates the in-process mirror *and* pushes to the terminal (OSC 52);
      # `#text` reads the mirror (which may lag the real OS clipboard, but is
      # always current for a copy→paste round-trip within the app).
      private def text_clipboard
        (window?.try(&.application) || Crysterm::Application.global).clipboard
      end

      # Copies the current selection to the clipboard (mirror + terminal). Returns
      # whether there was a selection, so `Ctrl-X` only deletes when something was
      # actually cut. Routed through the buffer protocol so a rich buffer carries
      # formats alongside the plain text.
      private def copy_selection : Bool
        return false unless r = selection_range
        buf_copy_to_clipboard(text_clipboard, r.begin, r.end, window?)
        true
      end

      # Runs the block (an insert) after removing any selected text, the two grouped
      # into ONE undo step (Qt: typing/pasting over a selection undoes as a single
      # action). Without a live selection no group is opened — wrapping every plain
      # keystroke in an edit block would seal it against the undo stack's typing
      # coalescing, turning each character into its own undo step. The
      # selection-less path still drops a stale collapsed anchor, as
      # `#delete_selection` does.
      private def edit_replacing_selection(&) : Nil
        if selection?
          buf_edit_group do
            delete_selection
            yield
          end
        else
          clear_selection
          yield
        end
      end

      # Inserts *text* at the cursor, replacing any selection, honoring
      # `max_length` by truncating to the remaining room. The `break` targets the
      # `edit_replacing_selection` block, so a full field inserts nothing.
      private def insert_capped(text : String) : Nil
        edit_replacing_selection do
          if ml = @max_length
            room = ml - buf_size
            break if room <= 0
            text = text[0, room] if text.size > room
          end
          insert_at_cursor text
        end
      end

      # Inserts the clipboard's current text at the cursor, replacing any
      # selection. Reads the in-process mirror (see `#text_clipboard`), so a
      # copy→paste round-trip within the app is synchronous. Honors `max_length` by
      # truncating the pasted text to the remaining room.
      private def paste_clipboard : Nil
        clip = text_clipboard
        # A rich buffer takes a rich payload wholesale (formats preserved);
        # everything else — and the rich buffer's own fallback, e.g. when
        # `max_length` would need truncation — pastes plain text.
        return if buf_paste_rich(clip)
        text = clip.text
        return if text.empty?
        insert_capped text
      end

      # Extra display columns painted left of real row *rl*'s text — block indent,
      # list markers, quote bars, alignment shift. 0 on a flat editor; a decorated
      # one overrides it from its per-row layout metadata. Every shared row/column
      # mapping (caret placement, mouse mapping, selection columns) applies it, so
      # decorated rows stay position-exact.
      private def row_text_x_offset(rl : Int32) : Int32
        0
      end

      # Nearest text-bearing real row to *rl* searching in direction *dir* (±1): a
      # decorated layout may interleave rows that hold no buffer positions (block
      # margins), which vertical caret motion must step over. Identity on a flat
      # editor.
      private def nearest_text_row(rl : Int32, dir : Int32) : Int32
        rl
      end

      # Maps `@cursor_pos` (a buffer position) to `{real_line, column}` in
      # the wrapped/displayed content (`@wrapped_lines`), using the fake->real line map
      # (`ftor`). Exact for the default (unaligned) text area; best-effort with
      # center/right alignment (real lines carry padding). Column is a codepoint
      # offset within the real line.
      private def cursor_rowcol : Tuple(Int32, Int32)
        c = @cursor_pos.clamp(0, buf_size)
        # `fake_line` is the logical (`\n`-delimited) line index; `col` is the
        # tab-expanded column within it — the SAME units `process_content` lays
        # `@wrapped_lines` out with. A TAB expands to `tab_char * tab_size`, so counting
        # raw codepoints would desync the caret by `tab_size - 1` per preceding
        # TAB.
        fake_line, col = cursor_line_col c

        reals = @wrapped_lines.ftor[fake_line]?
        if reals.nil? || reals.empty?
          rl = Math.max(0, @wrapped_lines.size - 1)
          return {rl, line_display_width(rl)}
        end

        rcol = col
        reals.each_with_index do |r, idx|
          w = line_display_width(r)
          last = idx == reals.size - 1
          # `rcol < w` keeps a mid-line position here; a boundary (`rcol == w`)
          # moves to the next wrapped piece, except on the final piece (line end).
          return {r, rcol} if rcol < w || (last && rcol <= w)
          rcol -= w
        end

        last_r = reals[-1]
        {last_r, line_display_width(last_r)}
      end

      # `{logical-line index, tab-expanded column}` of buffer position *c* — the
      # position→(fake line, col) half of `#cursor_rowcol`, separated so a document
      # adapter can override it with an O(log) block lookup instead of allocating
      # the whole `0..c` prefix. This flat default is line-local for the column
      # (only the slice from the last `\n` to *c*), but still counts newlines over
      # the prefix.
      private def cursor_line_col(c : Int32) : Tuple(Int32, Int32)
        head = buf_slice(0, c)
        nl = head.rindex('\n')
        {head.count('\n'), expanded_width(nl ? head[(nl + 1)..] : head)}
      end

      # Inverse of `cursor_rowcol`: maps a real (wrapped) line and a tab-expanded
      # column within it back to a buffer position. Used by Up/Down to land
      # the cursor on the visual row above/below at the desired column, and by
      # `#position_at` to map a mouse click to a buffer index.
      private def pos_from_rowcol(rl : Int32, col : Int32) : Int32
        rl = rl.clamp(0, Math.max(0, @wrapped_lines.size - 1))
        fake_line = @wrapped_lines.rtof[rl]? || 0

        # Expanded column within the fake (logical) line: the total expanded
        # width of preceding wrapped pieces of the same fake line, plus `col`
        # (itself expanded — see `cursor_rowcol`).
        exp_col = col
        (@wrapped_lines.ftor[fake_line]? || [rl]).each do |r|
          break if r >= rl
          exp_col += (@wrapped_lines[r]? || "").size
        end

        base, line_end = buf_line_bounds(fake_line)

        # Convert back to a raw buffer offset: a TAB counts as one editable
        # char, not its `tab_size` rendered columns.
        (base + unexpand_col_in(base, line_end, exp_col)).clamp(0, buf_size)
      end

      # Raw within-line offset for tab-expanded column *exp_col* on the logical
      # line spanning buffer range `[base, line_end)`. In the common tab-free
      # case the answer is just `min(exp_col, length)` — no line String is built;
      # only a line that actually contains a TAB is materialized and walked
      # (`#unexpand_col`).
      private def unexpand_col_in(base : Int32, line_end : Int32, exp_col : Int32) : Int32
        return Math.min(exp_col, line_end - base) unless buf_range_includes_tab?(base, line_end)
        unexpand_col(buf_line_text_at(base, line_end), exp_col)
      end

      # The whole text of fake (logical) line *fake_line* — the buffer slice its
      # `#buf_line_bounds` delimit. A `Buffer`-protocol hook (defined here, next
      # to its callers, rather than in `Buffer` itself) because a document
      # adapter already *holds* that String — one logical line is exactly one
      # block, whose `text` is cached — so the whole-line reads below can borrow
      # it instead of building a fresh copy per row per frame.
      private def buf_line_text(fake_line : Int32) : String
        buf_slice(*buf_line_bounds(fake_line))
      end

      # :ditto:, for a caller that already holds the line's bounds. *from* and
      # *to* MUST be exactly one logical line's `#buf_line_bounds`: an adapter
      # may answer from the line it finds at *from* and ignore *to*, so a
      # sub-range would silently come back widened.
      private def buf_line_text_at(from : Int32, to : Int32) : String
        buf_slice(from, to)
      end

      # Whether the buffer range `[from, to)` (always a single logical line at the
      # call sites) contains a TAB. Flat default: a cheap `String#index` byte scan
      # with no allocation.
      private def buf_range_includes_tab?(from : Int32, to : Int32) : Bool
        return false if to <= from
        idx = buf_index('\t', from)
        !!(idx && idx < to)
      end

      # The full display width (in the same tab-expanded codepoint units the caret
      # math and `@wrapped_lines` use) of the real (post-wrap) line *rl*.
      #
      # In wrap mode `@wrapped_lines[rl]` is the whole wrapped piece, so its size IS the
      # width. In non-wrap mode `@wrapped_lines[rl]` is only the horizontally *sliced*
      # viewport window (`_hslice`), so its size undercounts a line wider than the
      # viewport — reconstruct the real line from the buffer instead. Otherwise
      # Up/Down snaps a caret past the viewport back to ~viewport width, and a
      # selection entirely right of `content_width` paints no highlight.
      private def line_display_width(rl : Int32) : Int32
        if wrap_content?
          (@wrapped_lines[rl]? || "").size
        else
          expanded_width(buf_line_text(@wrapped_lines.rtof[rl]? || 0))
        end
      end

      # Maps an absolute screen point (as delivered by `Event::Mouse`) to the
      # nearest buffer position — the mouse-click counterpart of
      # `#cursor_rowcol`/`#pos_from_rowcol`, kept consistent with how
      # `#_update_cursor` actually places the caret, so clicking exactly where the
      # caret is drawn is a no-op. Assumes the `@wrapped_lines`/`@child_base_x` model; a
      # widget rendering a separately re-sliced line must override it. Returns the
      # current `#cursor_pos` unchanged when the widget has no on-window geometry
      # yet.
      def position_at(x : Int32, y : Int32) : Int32
        lpos = coords
        return cursor_pos unless lpos

        # Mirrors the row math in `#_update_cursor`: clamp to the visible
        # content rows, then add the scroll offset to get the real line index.
        max_line = max_content_row(lpos)
        line = (y - lpos.yi - itop).clamp(0, Math.max(0, max_line))
        # Add the clip-aware scroll offset (`lpos.base`) the base renderer uses,
        # not `@child_base`: an ancestor clip folds the clipped-top count into
        # `coords.base`, so mapping a click through `@child_base` alone lands
        # `clipped` lines above the clicked text.
        rl = (line + lpos.base).clamp(0, Math.max(0, @wrapped_lines.size - 1))

        if wrap_content?
          # `@wrapped_lines[rl]` is the actual painted (already tab-expanded) text for
          # this row — `#column_index` walks it directly by display width.
          rline = @wrapped_lines[rl]? || ""
          col = column_index(rline, x - lpos.xi - ileft - row_text_x_offset(rl))
          pos_from_rowcol(rl, col)
        else
          # Non-wrap: `@wrapped_lines[rl]` is horizontally *sliced* to the viewport (see
          # `_hslice`), so it can't be walked directly — reconstruct the real
          # line's own (tab-expanded) text from the buffer instead, and undo the
          # `@child_base_x` scroll to land back in that line's own column space.
          fake_line = @wrapped_lines.rtof[rl]? || 0
          base = buf_line_bounds(fake_line)[0]
          raw_line = buf_line_text(fake_line)
          expanded = expand_tabs(raw_line)

          target = (x - lpos.xi - ileft - row_text_x_offset(rl)).clamp(0, content_width) + @child_base_x
          base + unexpand_col(raw_line, column_index(expanded, target))
        end
      end

      # The codepoint index within *text* whose accumulated display width
      # (`#str_width`, wide-character aware) is nearest *target_col* — the
      # character boundary nearest a click at that pixel column. Rounds to the
      # nearest boundary (not always down), so clicking the right half of a wide
      # character lands after it. Walks whole grapheme clusters under
      # `#full_unicode?`, keeping the cursor off cluster-internal codepoints.
      private def column_index(text : String, target_col : Int32) : Int32
        return 0 if target_col <= 0
        return target_col.clamp(0, text.size) unless full_unicode?

        acc = 0
        idx = 0
        text.each_grapheme do |g|
          # `Unicode.width(g)` reads the grapheme's `@cluster` directly — equal
          # to `str_width(g.to_s)` here but without the per-grapheme `String`.
          w = Unicode.width g
          w = 1 if w <= 0 # zero-width (e.g. a lone combining mark): still one step
          return idx if acc + w / 2 > target_col
          acc += w
          idx += grapheme_cps g
        end
        idx
      end

      # Codepoint count of *s* after TAB expansion (`tab_char * tab_size`, exactly
      # as `process_content` expands it) — i.e. its width in the `@wrapped_lines` column
      # units the caret math runs in. Equal to `s.size` when *s* has no TAB.
      private def expanded_width(s : String) : Int32
        expand_tabs(s).size
      end

      # Expands TABs in *s* to `tab_char * tab_size`, exactly as `process_content`
      # lays out `@wrapped_lines`. Guards on `includes?('\t')` so a tab-free string is
      # returned untouched (the common fast path).
      private def expand_tabs(s : String) : String
        s.includes?('\t') ? s.gsub('\t', style.tab_char * style.tab_size) : s
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

        target = (rl + rows).clamp(0, Math.max(0, @wrapped_lines.size - 1))
        # Landing on a positionless row (a block margin) would bounce the caret
        # back to its source row — step over it in the direction of travel.
        target = nearest_text_row(target, rows < 0 ? -1 : 1)
        return if target == rl

        width = line_display_width(target)
        @cursor_pos = pos_from_rowcol(target, goal.clamp(0, width))
      end

      # Visual rows to move per Page Up/Down: one viewport's worth, less one row of
      # overlap for reading continuity (at least 1). "Viewport's worth" is *visible
      # content* rows, which excludes a shown horizontal bar's reserved row —
      # counting that row over-counts the page.
      private def page_rows
        Math.max(1, visible_content_rows - 1)
      end

      # Scroll the *viewport* (only `@child_base`) so the caret's real (wrapped)
      # row stays on window. `@child_offset` is left at 0 — the caret is
      # `@cursor_pos`, not a scroll offset — for a single scroll model shared with
      # the attached `ScrollBar`. Returns whether the view moved, so the caller can
      # re-render; this doesn't render itself.
      private def ensure_cursor_visible(rl : Int32? = nil) : Bool
        # Callers pass the row they already mapped so a movement keystroke doesn't
        # map `@cursor_pos` twice (here and again in `_update_cursor`).
        rl ||= cursor_rowcol[0]
        ensure_visible rl
      end

      # Display column of the caret within its (non-wrapped) logical line — the
      # width of the line prefix up to `@cursor_pos`. Derived from the buffer, not
      # the horizontally-sliced `@wrapped_lines`, so it stays correct while scrolled.
      #
      # TABs are expanded to `tab_char * tab_size` as `process_content` does, so
      # the caret is measured against columns actually shown and stays in sync
      # with the horizontal scroll base (`@child_base_x`), measured the same way.
      private def caret_display_column : Int32
        start = line_start_pos
        # Legacy width is the codepoint count; with no TAB in the line prefix the
        # caret column is just the span length, so skip building (and measuring)
        # the prefix String. The full-unicode path still measures display width.
        if !full_unicode? && !buf_range_includes_tab?(start, @cursor_pos)
          return @cursor_pos - start
        end
        str_width expand_tabs(buf_slice(start, @cursor_pos))
      end

      # Horizontal counterpart of `#ensure_cursor_visible`: when lines don't wrap,
      # scroll the column window the minimum amount to keep the caret on window,
      # so typing past the right edge follows it. No-op while wrapping (no
      # horizontal overflow). Returns whether the view moved.
      private def ensure_cursor_visible_x : Bool
        return false if wrap_content?
        ensure_visible_x caret_display_column
      end

      # Display width of the buffer span `[from, to)` (TAB-expanded,
      # wide-character aware) — the render-column distance between two buffer
      # indices on the same line. `#position_at`'s inverse, used to turn the
      # selection's buffer indices into the column range
      # `#selection_columns_for_row` paints. *from* must be at or before the start
      # of *to*'s line, so no embedded `\n` is sliced across.
      private def rendered_column(from : Int32, to : Int32) : Int32
        s = expand_tabs(buf_slice(from, to))
        str_width s
      end

      # The portion of `#selection_range` that falls on real (post-wrap) line *rl*,
      # as a `x - xi` column range for `Widget#base_render`'s highlight pass, or `nil`
      # when the selection doesn't touch this row.
      #
      # *rl* is `@child_base`-relative like everywhere else in this module — exact
      # for the default top-aligned case, approximate (like `#cursor_rowcol`
      # itself) under vertical center/bottom alignment.
      #
      # Columns are shifted left by `@child_base_x` so a horizontally-scrolled
      # non-wrap view highlights the right cells (0 in wrap mode, where there is no
      # horizontal scroll). A range whose start is left of the viewport comes back
      # with a negative `begin`, which the per-cell `includes?` check in `base_render`
      # handles correctly.
      protected def selection_columns_for_row(rl : Int32) : Range(Int32, Int32)?
        return unless selection_range
        return if rl < 0 || rl >= @wrapped_lines.size

        selection_columns_for_row rl, pos_from_rowcol(rl, 0), pos_from_rowcol(rl, line_display_width(rl))
      end

      # :ditto:
      #
      # Entry point for a caller that has *already* computed row *rl*'s buffer
      # bounds (the painter does, one line earlier): `pos_from_rowcol` walks the
      # fake line's piece list and `line_display_width` slices the whole logical
      # line out of the buffer, so recomputing them per painted row per frame is
      # the dominant cost of a live drag-selection.
      #
      # NOTE: call this only from `Widget::TextEdit`'s own painter.
      # `Widget::LineEdit` overrides the *1-arg* form above with entirely
      # different visible-window math, and the generic painter
      # (`Widget#base_render`) calls that 1-arg form — routing generic painting
      # here would silently bypass the override.
      protected def selection_columns_for_row(rl : Int32, line_start : Int32, line_end : Int32) : Range(Int32, Int32)?
        return unless range = selection_range
        return if rl < 0 || rl >= @wrapped_lines.size

        lo = Math.max(range.begin, line_start)
        hi = Math.min(range.end, line_end)
        return if lo >= hi

        off = row_text_x_offset(rl)
        col_lo = off + rendered_column(line_start, lo) - @child_base_x
        col_hi = off + rendered_column(line_start, hi) - @child_base_x
        col_lo...col_hi
      end
    end
  end
end
