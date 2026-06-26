# `LineEdit` subclasses `PlainTextEdit`, which the `widget/**` glob loads
# *after* this file (`lineedit` sorts before `plaintextedit`), so require the
# parent explicitly to make it available at class-definition time.
require "./plaintextedit"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![LineEdit screenshot](../../examples/widget/lineedit/lineedit-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class LineEdit < PlainTextEdit
      property secret : Bool = false
      property censor : Bool = false

      # Mask character shown for each hidden character when `censor` is on
      # (Qt's `lineedit-password-character`). Defaults to `*`.
      property password_character : Char = '*'

      # Greyed-out prompt shown while the box is empty, like Qt's
      # `QLineEdit#placeholderText`. It is purely visual: `#value` stays empty.
      property placeholder : String = ""

      getter value : String = ""

      # Submitted lines, oldest first — the input history walked by Up/Down
      # (like a shell prompt or Qt's editable combo). Public so an app can
      # pre-seed or inspect it.
      getter history = [] of String

      # Cursor into `@history`. `history.size` is the sentinel "on the live
      # line you're typing", so Up steps back from there and Down returns to it.
      @history_pos = 0
      # The half-typed line stashed on the first Up, restored when Down walks
      # back past the newest entry — so browsing history never loses your draft.
      @history_draft = ""

      def initialize(
        secret = nil,
        censor = nil,
        placeholder = nil,
        parse_tags = false,
        input_on_focus = true,
        scrollable = false,
        **plaintextedit,
      )
        super **plaintextedit, parse_tags: parse_tags, input_on_focus: input_on_focus, scrollable: scrollable

        secret.try { |v| @secret = v }
        censor.try { |v| @censor = v }
        placeholder.try { |v| @placeholder = v }
      end

      def _listener(e : Crysterm::Event::KeyPress)
        if e.key == Tput::Key::Enter
          e.accept
          record_history @value
          @_done.try do |done2|
            done2.call nil, @value
          end
          return
        end
        # Single-line, so Up/Down can't move between rows — repurpose them to
        # walk the input history instead.
        if e.key == Tput::Key::Up
          e.accept
          history_prev
          return
        end
        if e.key == Tput::Key::Down
          e.accept
          history_next
          return
        end
        super
      end

      # Append a just-submitted line to the history and reset the cursor to the
      # live line. Blank lines and an immediate repeat of the last entry are
      # skipped (shell `ignoredups`), so Up gives back meaningful commands.
      private def record_history(line)
        @history_pos = @history.size
        @history_draft = ""
        return if line.empty?
        return if !@history.empty? && @history.last == line
        @history << line
        @history_pos = @history.size
      end

      # Up: recall an older entry. On the first step off the live line, stash the
      # draft so Down can bring it back.
      private def history_prev
        return if @history.empty? || @history_pos == 0
        @history_draft = @value if @history_pos == @history.size
        @history_pos -= 1
        # A non-nil `value=` is an external set, which parks the cursor at the end.
        self.value = @history[@history_pos]
      end

      # Down: recall a newer entry, or step back onto the stashed draft once you
      # walk past the newest entry.
      private def history_next
        return if @history_pos >= @history.size
        @history_pos += 1
        self.value = @history_pos == @history.size ? @history_draft : @history[@history_pos]
      end

      def value=(value = nil)
        # A non-nil argument is an external set (cursor to the end); `nil` is a
        # redisplay that preserves the cursor (see `PlainTextEdit#value=`).
        external = !value.nil?
        value ||= @value
        value = value.gsub /\n/, ""
        # Always record the authoritative value, even when the display does not
        # need refreshing. `_listener` mutates `@value` directly, so the `@_value`
        # (last-displayed) guard alone can wrongly no-op an external set such as
        # `input.value = ""`, leaving stale text that accumulates across submits.
        @value = value
        @cursor_pos = external ? @value.size : @cursor_pos.clamp(0, @value.size)

        # Compute the string actually shown. `@_value` caches the *displayed*
        # text (not the raw value) so the dedup guard also fires the first time
        # an empty box needs to paint its placeholder.
        disp =
          if @value.empty? && !@placeholder.empty?
            # Show the placeholder while empty; the real value stays "".
            @placeholder
          elsif @secret
            ""
          elsif @censor
            # One mask char per user-perceived character (grapheme) under
            # full_unicode; per codepoint otherwise.
            @password_character.to_s * (full_unicode? ? value.graphemes.size : value.size)
          else
            val = @value.gsub /\t/, style.tab_char * style.tab_size
            # Show the tail of the value that fits the input's visible width
            # (`awidth - iwidth - 1`; the -1 leaves room for the cursor).
            cols = awidth - iwidth - 1
            if full_unicode?
              tail_within(val, cols)
            else
              # Legacy: one column per codepoint. Clamp to [0, val.size] — a very
              # narrow box makes `cols` negative and `val[-visible..]` would raise
              # IndexError (or drop leading chars); slicing from `val.size -
              # visible` shows the last `visible` chars (and "" when 0).
              visible = cols.clamp(0, val.size)
              val[(val.size - visible)..]
            end
          end

        if @_value != disp
          @_value = disp
          set_content disp
          _update_cursor
        end
      end

      def submit
        @__listener.try &.call Crysterm::Event::KeyPress.new '\r', Tput::Key::Enter
      end
    end
  end
end
