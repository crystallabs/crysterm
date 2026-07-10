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
    # It also declares `#prefix`/`#suffix`/`#editable?` (identical across both
    # widgets) and the `on_value_changed` hook that refreshes the displayed text.
    #
    # The two widgets differ only in their numeric type and a few small spots, so
    # the including widget must provide:
    #
    #   * `#value` / `#value=` / `#increment` / `#decrement` and `@minimum` /
    #     `@maximum` / `@step` — its numeric value/range logic (from
    #     `Mixin::RangedValue` for `SpinBox`, or defined directly);
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

      # Text shown before/after the number (Qt `QSpinBox#prefix`/`#suffix`).
      property prefix : String = ""
      property suffix : String = ""

      # Whether the value can be typed directly (Qt's `QAbstractSpinBox#readOnly`
      # inverted). When false the box only responds to stepping.
      property? editable : Bool = true

      # Refresh the displayed number whenever the value changes (`RangedValue`
      # hook, overriding its no-op default — include order matters: this mixin
      # must come after `Mixin::RangedValue` for the override to apply).
      protected def on_value_changed
        update_content
      end

      # Shared spin-box `#initialize` tail — both controls run it after `super`
      # (and after `DoubleSpinBox` sets up `@decimals`/`@fmt`): stores a
      # non-inverted range and a clamped `value` (the shared guard;
      # `RangedValue#init_range` does the `maximum >= minimum` fix-up an inverted
      # range would otherwise leave `#value` stuck under), wires key handling and
      # the wheel/blur handlers, and paints the initial content.
      protected def setup_spinbox_editing(value, wrap) : Nil
        @wrap = wrap
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress
        install_spinbox_editing

        update_content
      end

      # Installs the mouse-wheel and blur handlers. Call once from the including
      # widget's `#initialize` (after `super`).
      protected def install_spinbox_editing : Nil
        # Losing focus mid-edit discards the buffer (Qt restores the last valid
        # value rather than committing a half-typed one).
        on(Crysterm::Event::Blur) { cancel_edit if editing? }

        on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_up?
            # Discard any in-progress edit first, matching `#stepping_key`: while
            # `@editing` is non-nil the box shows the buffer, so a wheel step would
            # change the committed value invisibly (then be revealed by Escape or
            # overwritten by Enter).
            cancel_edit
            increment
            e.accept
            request_render
          elsif e.action.wheel_down?
            cancel_edit
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
          # Clamp here rather than leaning on `#value=`: on a `#wrap?` box,
          # `#value=` treats an out-of-range value as a single-step overshoot
          # and snaps to the *opposite* bound (typing 150 on a 0..100 wrap box
          # would commit 0). A typed entry is an absolute value, not a step, so
          # it must clamp into range regardless of `#wrap?`.
          self.value = v.clamp(@minimum, @maximum) # emits a value-change event if changed
        end
        update_content # revert the display even when value did not change
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
           # A leading `-` is only accepted as the first buffer character. Test
           # emptiness rather than `@editing.nil?`: backspacing to empty leaves a
           # non-nil `""`, so a nil check wrongly blocked re-entering `-` after a
           # full backspace. `(@editing || "").empty?` covers both cases while
           # still rejecting `-` mid-number.
           (ch == '-' && @minimum < 0 && (@editing || "").empty?))
          apply_edit(e) { @editing = (@editing || "") + ch }
          return
        end

        if k == ::Tput::Key::Enter && editing?
          commit_edit
          e.accept
          request_render
        elsif k == ::Tput::Key::Escape && editing?
          cancel_edit
          e.accept
          request_render
        elsif (k == ::Tput::Key::Backspace || k == ::Tput::Key::CtrlH) && editing?
          apply_edit(e) { @editing = @editing.to_s[0...-1] }
        elsif k == ::Tput::Key::Up || ch == 'k' || ch == '+'
          stepping_key(e) { increment }
        elsif k == ::Tput::Key::Down || ch == 'j'
          stepping_key(e) { decrement }
        elsif k == ::Tput::Key::PageUp
          stepping_key(e) { increment page_step_delta(@step) }
        elsif k == ::Tput::Key::PageDown
          stepping_key(e) { decrement page_step_delta(@step) }
        elsif k == ::Tput::Key::Home
          stepping_key(e) { self.value = @minimum }
        elsif k == ::Tput::Key::End
          stepping_key(e) { self.value = @maximum }
        end
      end

      # The PageUp/PageDown delta: 10 line-steps, saturating to the numeric
      # type's own bound instead of raising when `step * 10` overflows (e.g. a
      # `SpinBox` step above `Int32::MAX / 10`). `#increment`/`#decrement` then
      # saturate to the range bound as usual.
      private def page_step_delta(step : T) : T forall T
        step * 10
      rescue OverflowError
        step >= T.zero ? T::MAX : T::MIN
      end

      # Discards any in-progress edit buffer, runs the stepping *action*, then
      # accepts the event and repaints — shared by every value-stepping key
      # (Up/Down, `+`/`k`/`j`, PageUp/PageDown, Home/End). Block-yielding, so it
      # allocates no `Proc`.
      private def stepping_key(e, &) : Nil
        cancel_edit
        yield
        e.accept
        request_render
      end

      # Applies a buffer mutation (the *block* edits `@editing`), then refreshes
      # the displayed text, accepts the event and repaints — shared by the
      # buffer-editing keys (direct entry and Backspace), the display-side
      # counterpart to `#stepping_key`. Block-yielding, so it allocates no `Proc`.
      private def apply_edit(e, &) : Nil
        yield
        update_content
        e.accept
        request_render
      end
    end
  end
end
