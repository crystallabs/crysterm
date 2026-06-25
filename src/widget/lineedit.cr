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
          @_done.try do |done2|
            done2.call nil, @value
          end
          return
        end
        super
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
