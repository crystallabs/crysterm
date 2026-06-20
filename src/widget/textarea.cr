module Crysterm
  class Widget
    # Text area element
    class TextArea < Input
      @_reading = false

      @scrollable = true
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

      property _done : Proc(String?, String?, Nil)?
      property __done : Proc(String?, String?, Nil)?
      property __listener : Proc(Crysterm::Event::KeyPress, Nil)?

      @ev_read_input_on_focus : Crysterm::Event::Focus::Wrapper?
      @ev_enter : Crysterm::Event::KeyPress::Wrapper?
      @ev_reading : Crysterm::Event::KeyPress::Wrapper?
      @ev_done_blur : Crysterm::Event::Blur::Wrapper?

      def initialize(
        input_on_focus = false,
        **input,
      )
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

        # Keep that line within the visible viewport. Vertical scroll-follow for
        # content taller than the box is handled by `_type_scroll` on edits; for
        # pure movement the row is clamped to the visible range.
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
          # start/end of the current (logical) line. Up/Down are not handled
          # yet (they need column memory across wrapped lines).
          if k == Tput::Key::Left
            @cursor_pos -= cursor_prev_width
            _update_cursor
          elsif k == Tput::Key::Right
            @cursor_pos += cursor_next_width
            _update_cursor
          elsif k == Tput::Key::Home
            @cursor_pos = line_start_pos
            _update_cursor
          elsif k == Tput::Key::End
            @cursor_pos = line_end_pos
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
          elsif k == Tput::Key::Backspace || k == Tput::Key::CtrlH
            # Delete the grapheme cluster (base + combining marks, wide emoji, …)
            # immediately before the cursor, then move the cursor back over it.
            if @cursor_pos > 0
              w = cursor_prev_width
              @value = @value[0...(@cursor_pos - w)] + @value[@cursor_pos..]
              @cursor_pos -= w
            end
          elsif k == Tput::Key::Delete
            # Delete the grapheme cluster at the cursor; the cursor stays put.
            if @cursor_pos < @value.size
              w = cursor_next_width
              @value = @value[0...@cursor_pos] + @value[(@cursor_pos + w)..]
            end
          end
        end

        if e.char && (!e.key || also_check_char)
          # XXX can we avoid to_s ?
          unless e.char.to_s.matches? /^[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]$/
            # Insert the typed character at the cursor (not just at the end),
            # then advance the cursor past it.
            ch = e.char.to_s
            @value = @value[0...@cursor_pos] + ch + @value[@cursor_pos..]
            @cursor_pos += ch.size
          end
        end

        if @value != value
          screen.render
        end
      end

      def _type_scroll
        # O: XXX workaround
        h = aheight - iheight
        if (@_clines.size - @child_base) > h
          scroll @_clines.size
        end
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

      def submit
        # @__listener.try &.call Crysterm::Event::KeyPress.new '\n', Tput::Key::Enter
        return unless @__listener
        @__listener.try &.call Crysterm::Event::KeyPress.new '\n', Tput::Key::Enter
      end

      def cancel
        # @__listener.try &.call Crysterm::Event::KeyPress.new '\e', Tput::Key::Escape
        return unless @__listener
        @__listener.try &.call Crysterm::Event::KeyPress.new '\e', Tput::Key::Escape
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

      def read_input(&callback : Proc(String, String, Nil))
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
