module Crysterm
  module Mixin
    module TextEditing
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
        @ev_read_input_on_focus.try &.off

        # Then add the new one if asked
        if value
          @ev_read_input_on_focus = on(Crysterm::Event::FocusIn) do # |e|
            read_input
          end

          # The widget may be focused *already* — `Window#insert` auto-focuses
          # the first keyable widget during construction, i.e. before this
          # handler exists, so that `FocusIn` was emitted into the void and no
          # later one is coming (re-focusing an already-focused widget is a
          # no-op). Start the read now, or a first-created input field ignores
          # all keys until focus leaves and returns. Mirrors `Completer#attach`
          # (`install_filter widget if widget.focused?`).
          read_input if focused?
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

          # (Considered: echoing the edited character straight into the window's
          # cell buffer to skip a render. Not worth it — a direct write would
          # have to re-implement the wrapping, horizontal scroll, selection and
          # attribute handling the normal damage-limited render already does
          # cheaply, and typing is human-paced.)
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

        if !read_only? && (c = e.char) && (!e.key || also_check_char)
          # Ignore control characters. Deciding this *before* touching the
          # selection means a stray control keystroke doesn't clobber it. A real
          # character typed over a selection replaces it: drop the selection
          # first, then measure `max_length` against the freed-up length so a
          # replacement in a full field still works.
          unless TextEditing.control_char?(c)
            edit_replacing_selection do
              at_limit = (ml = @max_length) ? buf_size >= ml : false
              insert_at_cursor c.to_s unless at_limit
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
          # Serializing for the payload is itself skipped when nobody listens.
          emit Crysterm::Event::TextChanged, buf_text if text_change_observed?
          request_render
        end

        # Any keystroke that wasn't itself a kill ends the consecutive-kill run,
        # so the next kill starts a fresh ring entry (emacs semantics).
        kill_ring.interrupt if rl && !killed

        # Consume the event so window-level accelerators don't double-act on a
        # key this reading field already handled.
        e.accept if handled
      end

      # Whether *c* is a control character that should never be typed into the
      # buffer: tested straight on the codepoint — no per-keystroke `to_s`
      # `String` and no regex/`MatchData`. Equivalent to
      # `/[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]/`: every C0 control plus DEL, but
      # NOT TAB (0x09) / LF (0x0a) / CR (0x0d), which fall outside this class
      # and are kept. Shared with `Widget::TextEdit#table_guard`, whose
      # per-keystroke `typing` classification is the same rule (there
      # applied to a synthesized event's `#char` to gate table-cell typing) —
      # a module method so both sites (and any non-includer) share the one
      # predicate.
      def self.control_char?(c : Char) : Bool
        o = c.ord
        o <= 0x08 || o == 0x0b || o == 0x0c || (0x0e <= o <= 0x1f) || o == 0x7f
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

      def render(with_children = true)
        refresh_value
        super
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

      # Subscribes *block* to text changes — the block spelling of
      # `on(Event::TextChanged) { |e| ... }`, mirroring
      # `AbstractButton#on_clicked`; returns the `Subscription` so the caller
      # can disconnect. The block receives the new text.
      def on_text_changed(&block : String ->) : ::EventHandler::Subscription
        on(::Crysterm::Event::TextChanged) { |e| block.call e.value }
      end

      # :ditto: — present-tense spelling, kept as an alias of the past-tense
      # canonical (sugar names mirror their event names).
      def on_text_change(&block : String ->) : ::EventHandler::Subscription
        on_text_changed(&block)
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

        # @ev_reading.try &.off

        @ev_reading = on(Crysterm::Event::KeyPress) do |e|
          @__listener.try &.call e
        end

        @__done = @_done = ->_done_default(String?)

        # Store the wrapper so `__done_default` can remove it. Otherwise a new
        # Blur handler accumulates on every focus; worse, `rewind_focus` emits
        # Blur during teardown, so a stale handler would re-enter
        # `__done_default` and double-pop the focus history.
        @ev_done_blur = on(Crysterm::Event::FocusOut) do |e|
          # When focus moves to ANOTHER widget (Tab between form fields, click on
          # a sibling input), the user deliberately chose the new target: tear
          # down read state but do NOT `rewind_focus` (would yank focus back and
          # make Tab a no-op). Only rewind when focus is cleared entirely
          # (`e.next_focused.nil?`) or finishing via Enter/Escape. See `#__done_default`.
          @_skip_rewind = !e.next_focused.nil?
          @__done.try &.call nil
          @_skip_rewind = false
        end
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

        @ev_reading.try &.off
        @ev_reading = nil
        @_reading = false

        @_callback = nil
        @_done = nil
        @__listener = nil
        @ev_done_blur.try &.off
        @ev_done_blur = nil
        @__done = nil

        # All window-side teardown (cursor, key grab, focus restore) is skipped
        # when the widget is already detached — e.g. the read is being ended by a
        # `FocusOut` fired *during* the widget's own destruction/removal, when
        # `#window` would raise. The read-state cleanup above already ran; the
        # `Submitted`/`Cancelled`/`Activated` emits and the callback below don't
        # need a window, so a detached finish still notifies its listeners.
        if w = window?
          w.hide_cursor
          w.grab_keys = false

          # Restore the pre-read focus only when the read ended with focus cleared
          # (blur-to-nil, hide/detach) — NOT when the user deliberately moved focus
          # to another widget (Tab to a button, click on a sibling field), which
          # sets `@_skip_rewind`. Restoring then would yank focus back to the
          # pre-dialog widget, escaping the still-open modal dialog and, in the
          # field1→field2 chain, starting a read on a not-actually-focused field.
          # Otherwise drop the stale saved slot so a later unrelated
          # `restore_focus` can't replay it.
          if !focused? && !@_skip_rewind
            w.restore_focus
          else
            w.clear_saved_focus
          end

          if @input_on_focus && !@_skip_rewind && rewind_on_done?
            w.rewind_focus
          end
        end

        if data
          # `data` distinguishes submit (Enter, text) from cancel (Escape/blur,
          # nil) — `value` is always non-nil so it can't tell them apart.
          emit Crysterm::Event::Submitted, value
        else
          emit Crysterm::Event::Cancelled, value
        end

        # Exactly one `EditingFinished` per read session, emitted at
        # the session boundary regardless of how the session ended — Enter
        # (which also emits `Submitted` above, once, in this same single
        # teardown), focus-out, or Escape (which ends the whole session in
        # this model, so it counts as a finish, unlike Qt's revert-in-place).
        # The `@_reading` guard at the top of this method makes a re-entrant
        # blur during teardown a no-op, so this cannot double-fire.
        emit Crysterm::Event::EditingFinished

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
