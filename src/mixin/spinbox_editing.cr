module Crysterm
  module Mixin
    # Shared direct-entry/keyboard editing machinery for the spin-box controls
    # `Widget::SpinBox` (integer) and `Widget::DoubleSpinBox` (floating point).
    #
    # It centralizes the in-progress edit buffer (`@editing`), the displayed
    # `#text`, `#editing?`, `#update_content`, commit/cancel, the mouse-wheel and
    # blur wiring, and the whole `#on_keypress` dispatch (digit/sign entry,
    # Enter/Escape/Backspace, Up/Down/`+`/`k`/`j`, PageUp/PageDown, Home/End).
    #
    # The two widgets differ only in their numeric type and a few small spots, so
    # the including widget must provide:
    #
    #   * `#value` / `#value=` / `#increment` / `#decrement` and `@minimum` /
    #     `@maximum` / `@step` — its numeric value/range logic (from
    #     `Mixin::RangedValue` for `SpinBox`, or defined directly);
    #   * `#prefix` / `#suffix` and `#editable?` accessors;
    #   * `#parse_buffer(buf : String)` — parse the edit buffer to the widget's
    #     numeric type, returning `nil` on failure (`to_i?` / `to_f?`);
    #   * `#body_text : String` — the committed value as shown (e.g. `value.to_s`
    #     or a formatted string);
    #   * `#extra_entry_char?(ch : Char) : Bool` — whether *ch* is an accepted
    #     entry character beyond digits and a leading sign (e.g. a single `.`).
    #
    # The including widget wires the wheel/blur handlers by calling
    # `#install_spinbox_editing` from its own `#initialize`.
    module SpinBoxEditing
      # The in-progress edit buffer (`nil` when not editing). While editing, the
      # box shows this text instead of the committed value.
      @editing : String? = nil

      # Installs the mouse-wheel and blur handlers. Call once from the including
      # widget's `#initialize` (after `super`).
      protected def install_spinbox_editing : Nil
        # Losing focus mid-edit discards the buffer (Qt restores the last valid
        # value rather than committing a half-typed one).
        on(Crysterm::Event::Blur) { cancel_edit if editing? }

        # Mouse wheel nudges the value.
        on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_up?
            increment
            e.accept
            request_render
          elsif e.action.wheel_down?
            decrement
            e.accept
            request_render
          end
        end
      end

      # The text shown in the box: the edit buffer (while editing) or the
      # committed value (`#body_text`), framed by `prefix`/`suffix`.
      def text : String
        body = @editing || body_text
        "#{@prefix}#{body}#{@suffix}"
      end

      # Whether a value is currently being typed.
      def editing? : Bool
        !@editing.nil?
      end

      private def update_content
        set_content text
      end

      # Parses and commits the edit buffer (clamped into range via `#value=`),
      # then ends the editing session. An empty/invalid buffer just restores the
      # prior value.
      def commit_edit
        buf = @editing
        return unless buf
        @editing = nil
        if v = parse_buffer(buf)
          self.value = v # clamps and emits a value-change event if it actually changed
        end
        update_content # revert the display even when the value did not change
      end

      # Abandons the edit buffer and restores the committed value.
      def cancel_edit
        return unless @editing
        @editing = nil
        update_content
      end

      def on_keypress(e)
        k = e.key
        ch = e.char

        # Direct numeric entry: digits (and a leading `-` when negatives are in
        # range, plus any widget-specific `#extra_entry_char?`) build the buffer.
        if editable? && ch &&
           (('0'..'9').includes?(ch) ||
           extra_entry_char?(ch) ||
           # A leading `-` is only accepted as the *first* character of the
           # buffer. Test the buffer's emptiness rather than `@editing.nil?`:
           # backspacing every typed character leaves an empty *non-nil* buffer
           # (`""`), so the nil check wrongly blocked re-entering a negative sign
           # after a full backspace. `(@editing || "").empty?` covers both the
           # not-yet-editing (nil) and backspaced-to-empty ("") states, while
           # still rejecting a `-` typed mid-number.
           (ch == '-' && @minimum < 0 && (@editing || "").empty?))
          @editing = (@editing || "") + ch
          update_content
          e.accept
          request_render
          return
        end

        if k == ::Tput::Key::Enter
          commit_edit
          e.accept
          request_render
        elsif k == ::Tput::Key::Escape
          cancel_edit
          e.accept
          request_render
        elsif (k == ::Tput::Key::Backspace || k == ::Tput::Key::CtrlH) && editing?
          @editing = @editing.to_s[0...-1]
          update_content
          e.accept
          request_render
        elsif k == ::Tput::Key::Up || ch == 'k' || ch == '+'
          cancel_edit
          increment
          e.accept
          request_render
        elsif k == ::Tput::Key::Down || ch == 'j'
          cancel_edit
          decrement
          e.accept
          request_render
        elsif k == ::Tput::Key::PageUp
          cancel_edit
          increment @step * 10
          e.accept
          request_render
        elsif k == ::Tput::Key::PageDown
          cancel_edit
          decrement @step * 10
          e.accept
          request_render
        elsif k == ::Tput::Key::Home
          cancel_edit
          self.value = @minimum
          e.accept
          request_render
        elsif k == ::Tput::Key::End
          cancel_edit
          self.value = @maximum
          e.accept
          request_render
        end
      end
    end
  end
end
