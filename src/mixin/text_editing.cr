require "./text_editing/buffer"
require "./text_editing/flat_buffer"
require "./text_editing/document_buffer"

module Crysterm
  module Mixin
    # The "editable text buffer" concern: buffer, caret, wrapping, selection and
    # key handling, shared without inheritance.
    #
    # Qt's `QLineEdit` is a `QWidget`, *not* a `QAbstractScrollArea` (which is
    # `QPlainTextEdit`'s base). Crysterm mirrors that by sharing the editing
    # behavior as a module, so a widget can get it without becoming a scroll area.
    # The viewport machinery this calls (`@child_base`, `_clines`,
    # `ensure_visible`, `scroll`, `process_content`, …) lives on the base
    # `Widget`, so a plain `Box`/`Input` includer has it available.
    #
    # The including widget:
    #   * also includes a `Buffer` adapter — `FlatBuffer` (one `String`) or a
    #     `TextDocument`-backed one — supplying the `buf_*` methods and the
    #     `value`/`value=` widget API this module's shared logic calls;
    #   * calls `setup_text_editing` from `initialize` (after `super`) to wire the
    #     cursor-tracking and read handlers.
    module TextEditing
      include Buffer

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

      # The buffer's text — Qt's `QLineEdit#text` / `QPlainTextEdit#toPlainText`,
      # and the name to reach for on a text widget.
      #
      # A synonym for `#value`, which stays the *generic* widget-value name every
      # value widget answers to.
      def text : String
        value
      end

      # :ditto:
      def text=(text : String)
        self.value = text
      end

      # Inserts *str* at the cursor, replacing the selection if there is one —
      # exactly what typing the characters would do (Qt's `QLineEdit#insert`).
      #
      # Named `insert_text`, not `insert`: `Widget#insert` already means "insert a
      # child widget" (`Mixin::Children#insert`).
      def insert_text(str : String) : Nil
        # Nothing to insert and nothing to replace ⇒ no change, so no event and
        # no repaint (inserting `""` over a selection still deletes it).
        return if str.empty? && !selection?
        edit_replacing_selection { insert_at_cursor str }
        ensure_cursor_visible
        ensure_cursor_visible_x
        emit Crysterm::Event::TextChanged, buf_text
        request_render
        _update_cursor
      end

      # Insertion-point position, as a codepoint index into the buffer
      # (`0..buf_size`). Setting `value=` externally moves it to the end.
      # Movement and deletion step over whole grapheme clusters under
      # `full_unicode?`, a single codepoint otherwise.
      @cursor_pos = 0

      def cursor_position : Int32
        @cursor_pos
      end

      # Sets the cursor position, clamped to the valid buffer range
      # (`0..buf_size`).
      def cursor_position=(value : Int32) : Int32
        @cursor_pos = value.clamp(0, buf_size)
      end

      # Alias for `#cursor_position`. 327 call sites across the codebase use
      # this spelling; new code should prefer `#cursor_position`.
      def cursor_pos : Int32
        cursor_position
      end

      # Alias for `#cursor_position=`.
      def cursor_pos=(value : Int32) : Int32
        self.cursor_position = value
      end

      # The fixed end of an in-progress mouse selection (a codepoint index into the
      # buffer), or `nil` when nothing is selected. `#cursor_pos` is the other,
      # moving end. Any keyboard interaction or external `value=` drops it: there
      # is no keyboard-extend (Shift+arrow) support yet, so a plain keystroke
      # always means "the selection is no longer live".
      property selection_anchor : Int32? = nil

      # The selected range as `[lo, hi)` codepoint indices into the buffer, or
      # `nil` when nothing is selected (no anchor, or anchor and cursor coincide
      # — a plain click with no drag).
      def selection_range : Range(Int32, Int32)?
        return nil unless anchor = @selection_anchor
        lo, hi = anchor < cursor_pos ? {anchor, cursor_pos} : {cursor_pos, anchor}
        return nil if lo == hi
        lo...hi
      end

      # Whether anything is selected (Qt's `hasSelectedText`).
      def selection? : Bool
        !!selection_range
      end

      # The currently-selected substring of the buffer, or `""` when nothing is
      # selected.
      def selected_text : String
        (r = selection_range) ? buf_slice(r.begin, r.end) : ""
      end

      # Selects the whole buffer, parking the cursor at the end (Qt's
      # `selectAll`).
      def select_all : Nil
        @selection_anchor = 0
        @cursor_pos = buf_size
        @goal_col = nil
        request_render
      end

      # Drops the in-progress/completed mouse selection without moving the
      # cursor.
      def clear_selection : Nil
        @selection_anchor = nil
      end

      # While this widget is reading, Up/Down/Ctrl-U/Ctrl-D/PageUp/PageDown/Home/End
      # are editing keys routed to `#_listener`, so the `Mixin::Interactive` scroll
      # handler must stand down to avoid double-handling them (scrolling the
      # viewport AND moving the caret/killing text). Outside reading, viewer
      # scrolling is fine.
      def viewer_scroll_keys? : Bool
        !@_reading
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

      # Transient carrier for the `{real_line, col}` a keystroke's
      # `ensure_cursor_visible`/`_update_cursor` pair share, so `cursor_rowcol`
      # runs once per movement rather than twice. MUST be non-nil only for the
      # duration of that paired call, so no stale mapping leaks across keystrokes.
      @_pending_rowcol : Tuple(Int32, Int32)? = nil

      # Read-completion callbacks and the active key listener — internal read
      # machinery, no public accessors.
      @_done : Proc(String?, Nil)?
      @__done : Proc(String?, Nil)?
      @__listener : Proc(Crysterm::Event::KeyPress, Nil)?

      @ev_read_input_on_focus : Crysterm::Event::FocusIn::Wrapper?
      @ev_enter : Crysterm::Event::KeyPress::Wrapper?
      @ev_reading : Crysterm::Event::KeyPress::Wrapper?
      @ev_done_blur : Crysterm::Event::FocusOut::Wrapper?

      # Wires the cursor-following handlers and the optional Enter-to-read
      # accelerator. Call from `initialize` after `super`. `install_enter` installs
      # the Enter-to-read accelerator only when the caller explicitly asked for
      # `keys:`.
      private def setup_text_editing(input_on_focus = false, install_enter = false) : Nil
        on(Crysterm::Event::Resize) do
          _update_cursor
        end
        on(Crysterm::Event::Move) do
          _update_cursor
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

        # A paste (bracketed paste, routed by the window to the focused widget)
        # inserts at the cursor exactly as typing it would. A read-only widget
        # leaves the event unaccepted, so it still propagates/falls back.
        on(Crysterm::Event::Paste) do |e|
          next if read_only?
          insert_text sanitize_paste(e.content)
          e.accept
        end

        _setup_text_mouse
      end

      # Adapts pasted text to what this widget can hold before it is inserted.
      # The default keeps it verbatim (multiline editors take newlines as-is);
      # single-line widgets override (`Widget::LineEdit` flattens newlines).
      private def sanitize_paste(text : String) : String
        text
      end

      # Installs the click-to-position / drag-to-select mouse handler.
      #
      # A press moves the cursor to the clicked position and drops an anchor there.
      # It deliberately does NOT `#accept` the event: `Window#dispatch_mouse` still
      # needs to run its own default click-to-focus and emit `Event::Click`. This
      # handler owns only the cursor/selection side effect, not the click itself.
      #
      # A subsequent `Event::Mouse` reporting motion with a button still held
      # (`ev.button` is populated on `Move`, not just `Down`/`Up`) extends the
      # selection and repaints so the highlight tracks the drag live. Taking the
      # anchor lazily (`@selection_anchor ||=`) tolerates a drag whose initial
      # press this widget didn't see.
      private def _setup_text_mouse : Nil
        on(Crysterm::Event::Mouse) do |e|
          if e.action.down?
            @goal_col = nil
            pos = position_at(e.x, e.y)
            clicks = window?.try(&.click_count) || 1
            if clicks >= 3
              # Triple-click selects the whole logical line. An empty span must
              # leave the anchor nil, never seed it at the caret — see the
              # single-click branch below.
              @cursor_pos = pos
              a = line_start_pos
              b = line_end_pos
              @selection_anchor = (a == b ? nil : a)
              @cursor_pos = b
            elsif clicks == 2
              # Double-click selects the word under the pointer. On non-word text
              # `word_bounds_at` returns an empty `{pos, pos}`, which must leave
              # the anchor nil — see the single-click branch below.
              a, b = word_bounds_at(pos)
              @selection_anchor = (a == b ? nil : a)
              @cursor_pos = b
            else
              @cursor_pos = pos
              # A plain click positions the caret with NO selection. An anchor
              # equal to the caret is a landmine: it reports as "no selection"
              # only while the caret sits on it, and the next cursor-moving edit
              # leaves it behind as a bogus range whose end can exceed the
              # now-shorter value, crashing `#delete_selection` with an IndexError.
              # The drag path seeds the anchor lazily on first motion instead.
              @selection_anchor = nil
            end
            # Capture the mouse so a drag that leaves our bounds keeps extending
            # the selection (released on button-up in `Window#dispatch_mouse`).
            window?.try &.capture_mouse(self)
            # Reflect the reposition/selection ourselves rather than relying on
            # `dispatch_mouse`'s click-to-focus render, which is skipped when
            # `focus_on_click?` is off. `render` repositions the terminal caret via
            # `_update_cursor` too.
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

      # The maximum visible content-row index for the viewport described by *lpos*.
      # Each caller applies its own `.clamp` tail, whose first operand differs.
      private def max_content_row(lpos) : Int32
        (lpos.yl - lpos.yi) - ivertical - 1
      end

      # During a drag-select, scrolls one row when the pointer is past the top or
      # bottom of the visible content, so the selection can extend beyond the
      # viewport. Returns whether it scrolled. No-op for a non-scrollable widget.
      # Uses the same row geometry as `#position_at`.
      private def autoscroll_for_drag(y : Int32) : Bool
        return false unless @scrollable
        lpos = @lpos || coords
        return false unless lpos
        max_line = max_content_row(lpos)
        raw = y - lpos.yi - itop
        before = @child_base
        if raw < 0
          scroll(-1)
        elsif raw > max_line
          scroll(1)
        end
        @child_base != before
      end

      # A text editor's "scrollable right now" is a real content-vs-height overflow
      # test, not the `@shrink_to_fit` always-scrollable short-circuit inherited
      # from `Input`, which would show an `AsNeeded` vertical bar even when the
      # content fits.
      def overflows_y?
        content_overflows_height?
      end

      # Reserves one extra right-edge column beyond the scroll bar's so the caret
      # has somewhere to sit at the end of a full-width line.
      def content_margin_x : Int32
        super + 1
      end

      def _update_cursor(get = false)
        return unless focused? # if window.focused != self

        lpos = get ? @lpos : coords
        # XXX is above a bug and should be vice-versa? `get ? coords : @lpos`
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
          rline = @_clines[rl]? || ""
          c = col.clamp(0, rline.size)
          # `@_clines[rl]` is the already-tab-expanded display piece, so in the
          # legacy (non-full-unicode) width path its `[0, c)` width IS `c` — no
          # substring needs to be built to measure a length already in hand.
          w = full_unicode? ? str_width(rline[0...c]) : c
          cx = lpos.xi + ileft + row_text_x_offset(rl) + w
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

      # Codepoint count of a grapheme cluster, read from the stdlib-internal
      # `@cluster` ivar (`Char | String`) so the common single-`Char` cluster
      # costs no `to_s` allocation. Identical to `g.to_s.size` (a `String`-backed
      # cluster is always multi-codepoint; a `Char` one is exactly 1).
      private def grapheme_cps(g : String::Grapheme) : Int32
        case cluster = g.@cluster
        in Char   then 1
        in String then cluster.size
        end
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
        return false unless start < @cursor_pos
        @goal_col = nil
        kill_ring.kill buf_slice(start, @cursor_pos), prepend: true
        buf_delete(start, @cursor_pos)
        @cursor_pos = start
        clear_selection
        true
      end

      # Kill the text between the cursor and *stop* (a buffer position *after* the
      # cursor): push it onto the kill ring, leaving the cursor put. Returns
      # whether anything was killed.
      private def kill_forward_to(stop) : Bool
        return false unless stop > @cursor_pos
        @goal_col = nil
        kill_ring.kill buf_slice(@cursor_pos, stop)
        buf_delete(@cursor_pos, stop)
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
      # the wrapped/displayed content (`@_clines`), using the fake->real line map
      # (`ftor`). Exact for the default (unaligned) text area; best-effort with
      # center/right alignment (real lines carry padding). Column is a codepoint
      # offset within the real line.
      private def cursor_rowcol : Tuple(Int32, Int32)
        c = @cursor_pos.clamp(0, buf_size)
        # `fake_line` is the logical (`\n`-delimited) line index; `col` is the
        # tab-expanded column within it — the SAME units `process_content` lays
        # `@_clines` out with. A TAB expands to `tab_char * tab_size`, so counting
        # raw codepoints would desync the caret by `tab_size - 1` per preceding
        # TAB.
        fake_line, col = cursor_line_col c

        reals = @_clines.ftor[fake_line]?
        if reals.nil? || reals.empty?
          rl = Math.max(0, @_clines.size - 1)
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
        unexpand_col(buf_slice(base, line_end), exp_col)
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
      # math and `@_clines` use) of the real (post-wrap) line *rl*.
      #
      # In wrap mode `@_clines[rl]` is the whole wrapped piece, so its size IS the
      # width. In non-wrap mode `@_clines[rl]` is only the horizontally *sliced*
      # viewport window (`_hslice`), so its size undercounts a line wider than the
      # viewport — reconstruct the real line from the buffer instead. Otherwise
      # Up/Down snaps a caret past the viewport back to ~viewport width, and a
      # selection entirely right of `content_width` paints no highlight.
      private def line_display_width(rl : Int32) : Int32
        if wrap_content?
          (@_clines[rl]? || "").size
        else
          fake_line = @_clines.rtof[rl]? || 0
          base, line_end = buf_line_bounds(fake_line)
          expanded_width(buf_slice(base, line_end))
        end
      end

      # Maps an absolute screen point (as delivered by `Event::Mouse`) to the
      # nearest buffer position — the mouse-click counterpart of
      # `#cursor_rowcol`/`#pos_from_rowcol`, kept consistent with how
      # `#_update_cursor` actually places the caret, so clicking exactly where the
      # caret is drawn is a no-op. Assumes the `@_clines`/`@child_base_x` model; a
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
        rl = (line + lpos.base).clamp(0, Math.max(0, @_clines.size - 1))

        if wrap_content?
          # `@_clines[rl]` is the actual painted (already tab-expanded) text for
          # this row — `#column_index` walks it directly by display width.
          rline = @_clines[rl]? || ""
          col = column_index(rline, x - lpos.xi - ileft - row_text_x_offset(rl))
          pos_from_rowcol(rl, col)
        else
          # Non-wrap: `@_clines[rl]` is horizontally *sliced* to the viewport (see
          # `_hslice`), so it can't be walked directly — reconstruct the real
          # line's own (tab-expanded) text from the buffer instead, and undo the
          # `@child_base_x` scroll to land back in that line's own column space.
          fake_line = @_clines.rtof[rl]? || 0
          base, line_end = buf_line_bounds(fake_line)
          raw_line = buf_slice(base, line_end)
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
      # as `process_content` expands it) — i.e. its width in the `@_clines` column
      # units the caret math runs in. Equal to `s.size` when *s* has no TAB.
      private def expanded_width(s : String) : Int32
        expand_tabs(s).size
      end

      # Expands TABs in *s* to `tab_char * tab_size`, exactly as `process_content`
      # lays out `@_clines`. Guards on `includes?('\t')` so a tab-free string is
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

        target = (rl + rows).clamp(0, Math.max(0, @_clines.size - 1))
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
      # the horizontally-sliced `@_clines`, so it stays correct while scrolled.
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
      # as a `x - xi` column range for `Widget#_render`'s highlight pass, or `nil`
      # when the selection doesn't touch this row.
      #
      # *rl* is `@child_base`-relative like everywhere else in this module — exact
      # for the default top-aligned case, approximate (like `#cursor_rowcol`
      # itself) under vertical center/bottom alignment.
      #
      # Columns are shifted left by `@child_base_x` so a horizontally-scrolled
      # non-wrap view highlights the right cells (0 in wrap mode, where there is no
      # horizontal scroll). A range whose start is left of the viewport comes back
      # with a negative `begin`, which the per-cell `includes?` check in `_render`
      # handles correctly.
      protected def selection_columns_for_row(rl : Int32) : Range(Int32, Int32)?
        return nil unless range = selection_range
        return nil if rl < 0 || rl >= @_clines.size

        line_start = pos_from_rowcol(rl, 0)
        line_end = pos_from_rowcol(rl, line_display_width(rl))

        lo = Math.max(range.begin, line_start)
        hi = Math.min(range.end, line_end)
        return nil if lo >= hi

        off = row_text_x_offset(rl)
        col_lo = off + rendered_column(line_start, lo) - @child_base_x
        col_hi = off + rendered_column(line_start, hi) - @child_base_x
        col_lo...col_hi
      end

      # Pure viewport scroll: shift `@child_base` by *offset* wrapped rows, keeping
      # `@child_offset` at 0 so `scroll_position == child_base` and the bound
      # `ScrollBar` reflects/drives the view top. Overrides the base `#scroll`,
      # whose `@child_offset` book-keeping models a moving cursor/selection —
      # tracked here as `@cursor_pos` instead. The caret is untouched and may
      # scroll out of view, as in Qt's text edit.
      def scroll(offset = 1, always = false)
        return unless @scrollable && window?
        # Count *visible content* rows, which excludes a shown horizontal bar's
        # reserved row; counting it over-counts the viewport, stopping the view one
        # line short of the bar.
        visible = visible_content_rows
        return if visible <= 0

        mark_dirty
        base = @child_base
        @child_offset = 0
        @child_base = (base + offset).clamp(0, Math.max(0, scroll_height - visible))
        return emit Crysterm::Event::Scroll, 0 if @child_base == base

        process_content
        clamp_child_base_to_content
        emit Crysterm::Event::Scroll, @child_base - base
      end

      # Whether focusing this widget starts a read automatically (Qt has no
      # direct equivalent; closest to a one-shot `QLineEdit` prompt).
      getter? input_on_focus : Bool

      def input_on_focus=(value : Bool) : Bool
        @input_on_focus = value

        # Always remove any current handler
        @ev_read_input_on_focus.try { |w| off Crysterm::Event::FocusIn, w }

        # Then add the new one if asked
        if value
          @ev_read_input_on_focus = on(Crysterm::Event::FocusIn) do # |e|
            read_input
          end
        end

        value
      end

      # ameba:disable Metrics/CyclomaticComplexity
      def _listener(e : ::Crysterm::Event::KeyPress)
        done = @_done
        # Change detection without serializing the whole document twice per key
        # (`buf_text` is O(document) for the rich adapter). With no selection at
        # the start, every content-changing edit here also changes the size, so a
        # size snapshot suffices. A size-preserving change is only possible by
        # replacing a selection, so capture the pre-edit text just in that case.
        before_size = buf_size
        before = selection? ? buf_text : nil
        also_check_char = false
        # Emacs/readline editing keys (gated by config). `killed` records whether
        # this keystroke was a kill, so consecutive kills accumulate in the ring
        # (any other action breaks the run via `kill_ring.interrupt` below).
        rl = Crysterm::Config.input_readline_keys
        killed = false
        # Whether the editor consumed this keystroke. Used to `#accept` the event
        # so sibling window-level accelerators stand down for keys the field
        # handled — `grab_keys` stops propagation *up the widget tree* but not
        # other window-level KeyPress listeners on the same emission. Keys the
        # editor ignores stay un-accepted so those accelerators still fire.
        handled = false

        if k = e.key
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

          # A plain (non-extending) Left/Right over a live selection collapses the
          # caret to the selection's near edge — its start for Left, its end for
          # Right — instead of stepping one grapheme past it, matching Qt's
          # `QLineEdit`. Must be captured before the move mutates the cursor.
          collapse_sel = extend_sel ? nil : selection_range

          # Cursor movement. Left/Right step over a whole grapheme cluster under
          # `full_unicode?` (a single codepoint otherwise). Home/End jump to the
          # start/end of the current line. Up/Down move one visual row and Page
          # Up/Down a viewport's worth, both remembering the goal column
          # (`@goal_col`) so a detour across shorter lines keeps the column.
          moved = true
          if k == Tput::Key::Left
            @goal_col = nil
            @cursor_pos = collapse_sel ? collapse_sel.begin : @cursor_pos - cursor_prev_width
          elsif k == Tput::Key::Right
            @goal_col = nil
            @cursor_pos = collapse_sel ? collapse_sel.end : @cursor_pos + cursor_next_width
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
            @cursor_pos = buf_size
            extend_sel = true               # keep the just-set anchor
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
          had_sel = selection?
          clear_selection if moved && !extend_sel

          if moved
            # Map the caret once and share it: `ensure_cursor_visible` needs the
            # row, `_update_cursor` needs row+col, and neither `@cursor_pos` nor
            # the mapping changes between them.
            rc = cursor_rowcol
            # Follow the cursor on both axes (no-op if already visible);
            # re-render if it moved, then place the terminal cursor.
            scrolled = ensure_cursor_visible rc[0]
            scrolled = ensure_cursor_visible_x || scrolled
            # A selecting move must always repaint (the highlight changed even
            # when the view didn't scroll); a plain move only when it scrolled.
            # Collapsing a selection (`had_sel` cleared just above) must repaint
            # too — otherwise the previously highlighted cells stay painted, since
            # `_update_cursor` only moves the terminal caret.
            request_render if scrolled || extend_sel || had_sel
            @_pending_rowcol = rc
            _update_cursor
            @_pending_rowcol = nil
          end

          # XXX
          # if @keys && CtrlE
          #  # return(Invoke editor)
          # end

          # TODO can optimize by writing directly to window buffer
          # here.
          clipboard = Crysterm::Config.input_clipboard_keys

          # Track whether one of the editing keys below consumed the keystroke.
          edited = true
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
                buf_delete(@cursor_pos - w, @cursor_pos)
                @cursor_pos -= w
              end
            end
          elsif !read_only? && k == Tput::Key::Delete
            # A selection deletes as one unit; otherwise remove the grapheme
            # cluster at the cursor, leaving the cursor put.
            unless delete_selection
              if @cursor_pos < buf_size
                @goal_col = nil
                w = cursor_next_width
                buf_delete(@cursor_pos, @cursor_pos + w)
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
            stop += 1 if stop == @cursor_pos && @cursor_pos < buf_size
            killed = kill_forward_to stop
          elsif rl && !read_only? && k == Tput::Key::CtrlY # yank
            # Yank behaves like paste: replaces a live selection (grouped
            # into one undo step) and honors `max_length` by truncating the
            # ring entry to the room left.
            if text = kill_ring.yank
              insert_capped text
            end
          else
            edited = false
          end

          # A cursor movement or an editing action consumed this key.
          handled = true if moved || edited
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
            edit_replacing_selection do
              at_limit = (ml = @max_length) ? buf_size >= ml : false
              insert_at_cursor ch unless at_limit
            end
            # A printable character was consumed (even if the field was full and
            # the insert was suppressed) — don't let it also trigger a hotkey.
            handled = true
          end
        end

        if before
          # A selection was present: a same-size replacement is possible, so
          # compare the full text (both endpoints already needed the serialize).
          if (after = buf_text) != before
            emit Crysterm::Event::TextChanged, after
            request_render
          end
        elsif buf_size != before_size
          # No starting selection: a size change is the only way the text changed,
          # so an unchanged size means unchanged text — no serialization at all.
          emit Crysterm::Event::TextChanged, buf_text
          request_render
        end

        # Any keystroke that wasn't itself a kill ends the consecutive-kill run,
        # so the next kill starts a fresh ring entry (emacs semantics).
        kill_ring.interrupt if rl && !killed

        # Consume the event so window-level accelerators don't double-act on a
        # key this reading field already handled.
        e.accept if handled
      end

      protected def _type_scroll
        # Follow the cursor after an edit (or external `value=`), rather than
        # always jumping to the bottom — typing mid-document in a taller-than-box
        # buffer would otherwise push the just-typed character off-window.
        # Appending at the end still scrolls down since the cursor is there.
        # No render here — `value=` calls this from within its own render.
        ensure_cursor_visible
        ensure_cursor_visible_x
      end

      def render
        refresh_value
        super # OR _render
      end

      # Finishes the current read, submitting the entered text. Calls the
      # done-callback directly (rather than routing Enter through `@__listener`,
      # which treats Enter as inserting a newline) so `Submitted`/`read_input` fires.
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

      # Empties the buffer (Qt's `clear`). An external set, so the caret parks at
      # the start, the selection drops, and `Event::TextChanged` fires.
      def clear
        self.value = ""
      end

      protected def _read_input
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
        @ev_done_blur = on(Crysterm::Event::FocusOut) { |e|
          # When focus moves to ANOTHER widget (Tab between form fields, click on
          # a sibling input), the user deliberately chose the new target: tear
          # down read state but do NOT `rewind_focus` (would yank focus back and
          # make Tab a no-op). Only rewind when focus is cleared entirely
          # (`e.next_focused.nil?`) or finishing via Enter/Escape. See `#__done_default`.
          @_skip_rewind = !e.next_focused.nil?
          @__done.try &.call nil
          @_skip_rewind = false
        }
      end

      def read_input(&callback : String? ->)
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

      protected def __done_default(data : String? = nil)
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
        @ev_done_blur.try { |w| off Crysterm::Event::FocusOut, w }
        @ev_done_blur = nil
        @__done = nil

        window.hide_cursor
        window.grab_keys = false

        # Restore the pre-read focus only when the read ended with focus cleared
        # (blur-to-nil, hide/detach) — NOT when the user deliberately moved focus
        # to another widget (Tab to a button, click on a sibling field), which
        # sets `@_skip_rewind`. Restoring then would yank focus back to the
        # pre-dialog widget, escaping the still-open modal dialog and, in the
        # field1→field2 chain, starting a read on a not-actually-focused field.
        # Otherwise drop the stale saved slot so a later unrelated
        # `restore_focus` can't replay it.
        if !focused? && !@_skip_rewind
          window.restore_focus
        else
          window.clear_saved_focus
        end

        if @input_on_focus && !@_skip_rewind && rewind_on_done?
          window.rewind_focus
        end

        if data
          # `data` distinguishes submit (Enter, text) from cancel (Escape/blur,
          # nil) — `value` is always non-nil so it can't tell them apart.
          emit Crysterm::Event::Submitted, value
        else
          emit Crysterm::Event::Cancelled, value
        end

        emit Crysterm::Event::Activated, value

        # Invoke the `read_input(&callback)` block with the entered string
        # (`nil` = cancelled). blessed's dead `(err, data)` arity is gone: this
        # event-driven read path has no error source.
        callback.try &.call(data)

        nil
      end

      protected def _done_default(data : String? = nil)
        __done_default data
      end
    end
  end
end
