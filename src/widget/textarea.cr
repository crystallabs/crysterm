module Crysterm
  class Widget
    # Text area element
    #
    # <!-- widget-examples:capture v1 -->
    # ![TextArea screenshot](../../examples/widget/textarea/textarea-capture.png)
    # <!-- /widget-examples:capture -->
    class TextArea < Input
      @_reading = false

      @scrollable = true
      # NOTE: intentionally NOT defaulting `scrollbar_policy` to `AsNeeded` yet.
      # Here `@child_offset` is the *cursor* row offset, so a dragged bar driving
      # `scroll_to` would fight the cursor model. Unifying that (folding
      # `ensure_cursor_visible` onto the shared scroll machinery) is its own pass
      # (see SCROLLBAR-EXTRACTION-PLAN.md, workstream C / decision #4). Callers
      # can still opt in explicitly with `scrollbar: true`.
      @input_on_focus = false

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

      def initialize(
        input_on_focus = false,
        max_length = nil,
        read_only = false,
        **input,
      )
        @max_length = max_length
        @read_only = read_only
        # Will be taken care of by default above, and parent
        # scrollable.try { |v| @scrollable = v }

        @value = input["content"]? || ""
        @cursor_pos = @value.size

        super **(input.merge({keys: true}))

        # No need to register for keys here: `Widget#initialize` already does
        # that for any widget that asks for keys (`keys`/`input`).

        @__update_cursor = ->_update_cursor

        on(Crysterm::Event::Resize) do
          @__update_cursor.try &.call
        end
        on(Crysterm::Event::Move) do
          @__update_cursor.try &.call
        end

        self.input_on_focus = input_on_focus

        if !@input_on_focus && input["keys"]?
          @ev_enter = on(Crysterm::Event::KeyPress) do |e|
            next if @_reading
            if e.key.try &.==(Tput::Key::Enter)
              next read_input
            end
          end
        end

        # XXX if mouse...
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

        rline = @_clines[rl]? || ""
        prefix = rline[0...col.clamp(0, rline.size)]
        cx = lpos.xi + ileft + str_width(prefix)

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
        col = nl ? c - (nl + 1) : c

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

      # Inverse of `cursor_rowcol`: maps a real (wrapped) line and a codepoint
      # column within it back to an index into `@value`. Used by Up/Down to land
      # the cursor on the visual row above/below at the desired column.
      private def pos_from_rowcol(rl : Int32, col : Int32) : Int32
        rl = rl.clamp(0, Math.max(0, @_clines.size - 1))
        fake_line = @_clines.rtof[rl]? || 0

        # Offset of this real line's start within its fake (logical) line: the
        # total codepoints of the preceding wrapped pieces of the same fake line.
        offset = 0
        (@_clines.ftor[fake_line]? || [rl]).each do |r|
          break if r >= rl
          offset += (@_clines[r]? || "").size
        end

        # Start of the fake (logical) line within `@value`; logical lines are
        # joined by '\n', so each preceding one contributes its size plus one.
        base = 0
        fake = @_clines.fake
        fake_line.times { |k| base += (fake[k]? || "").size + 1 }

        (base + offset + col).clamp(0, @value.size)
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
      # one row of overlap for reading continuity (at least 1).
      private def page_rows
        Math.max(1, (aheight - iheight) - 1)
      end

      # Reconcile the scroll bookkeeping with the cursor's real (wrapped) row so
      # the cursor stays on screen and `child_base`/`child_offset` — which drive
      # the content offset and the scrollbar — agree with `@cursor_pos`. Scrolls
      # the viewport when the cursor crosses the top/bottom edge. Returns whether
      # the scroll position changed (so the caller can re-render); does not
      # render itself, since the edit path calls this from within a render.
      #
      # Without this, vertical movement only moved `@cursor_pos`: once the cursor
      # passed the top/bottom visible row the view never followed, leaving the
      # cursor pinned to the edge while editing a line that was scrolled off (so
      # typed text landed off-screen or painted at a stale position).
      private def ensure_cursor_visible : Bool
        return false unless @scrollable
        visible = aheight - iheight
        return false if visible <= 0

        rl, _ = cursor_rowcol
        base = @child_base
        offset = @child_offset

        if rl < @child_base
          @child_base = rl
        elsif rl > @child_base + visible - 1
          @child_base = rl - (visible - 1)
        end
        @child_base = @child_base.clamp(0, Math.max(0, @_clines.size - visible))
        @child_offset = (rl - @child_base).clamp(0, visible - 1)

        if @child_base != base || @child_offset != offset
          emit Crysterm::Event::Scroll
          return true
        end
        false
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

      def _listener(e)
        done = @_done
        value = @value
        also_check_char = false

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
          else
            moved = false
          end

          if moved
            # Scroll the viewport to follow the cursor (no-op when it is already
            # visible); re-render if it moved, then place the terminal cursor at
            # its new position.
            request_render if ensure_cursor_visible
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
      end

      def _type_scroll
        # Follow the cursor after an edit (or an external `value=`), rather than
        # always jumping to the bottom: when typing in the middle of a document
        # taller than the box, snapping to the end would push the just-typed
        # character off-screen. Appending at the end still scrolls down, because
        # the cursor is then on the last line. No render here — `value=` calls
        # this from within the widget's own render.
        ensure_cursor_visible
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
      # routed an Enter keypress through `@__listener`, but the TextArea listener
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

      def _done_default(err = nil, data = nil, &callback : Proc(String, String, Nil))
        __done_default err, data
        callback.call err, value
      end
    end
  end
end
