module Crysterm
  class Widget
    class TextBox < TextArea
      property secret : Bool = false
      property censor : Bool = false
      getter value : String = ""

      def initialize(
        secret = nil,
        censor = nil,
        parse_tags = false,
        input_on_focus = true,
        scrollable = false,
        **textarea,
      )
        super **textarea, parse_tags: parse_tags, input_on_focus: input_on_focus, scrollable: scrollable

        secret.try { |v| @secret = v }
        censor.try { |v| @censor = v }
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
        value ||= @value
        value = value.gsub /\n/, ""
        # Always record the authoritative value, even when the display does not
        # need refreshing. `_listener` mutates `@value` directly, so the `@_value`
        # (last-displayed) guard alone can wrongly no-op an external set such as
        # `input.value = ""`, leaving stale text that accumulates across submits.
        @value = value

        if @_value != value
          @_value = value

          if @secret
            set_content ""
          elsif @censor
            # One mask char per user-perceived character (grapheme) under
            # full_unicode; per codepoint otherwise.
            set_content "*" * (full_unicode? ? value.graphemes.size : value.size)
          else
            val = @value.gsub /\t/, style.tab_char * style.tab_size
            # Show the tail of the value that fits the input's visible width
            # (`awidth - iwidth - 1`; the -1 leaves room for the cursor).
            cols = awidth - iwidth - 1
            if full_unicode?
              set_content tail_within(val, cols)
            else
              # Legacy: one column per codepoint. Clamp to [0, val.size] — a very
              # narrow box makes `cols` negative and `val[-visible..]` would raise
              # IndexError (or drop leading chars); slicing from `val.size -
              # visible` shows the last `visible` chars (and "" when 0).
              visible = cols.clamp(0, val.size)
              set_content val[(val.size - visible)..]
            end
          end

          _update_cursor
        end
      end

      def submit
        @__listener.try &.call Crysterm::Event::KeyPress.new '\r', Tput::Key::Enter
      end
    end
  end
end
