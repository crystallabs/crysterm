module Crysterm
  module Mixin
    # Shared direct-entry/keyboard editing machinery for spin-box controls,
    # numeric type left open.
    #
    # Provides the in-progress edit buffer (`@editing`), the displayed `#text`,
    # `#editing?`, `#update_content`, commit/cancel, the mouse-wheel and blur
    # wiring, `#prefix`/`#suffix`/`#editable?`, the `on_value_changed` hook, and
    # the whole `#on_keypress` dispatch (digit/sign entry, Enter/Escape/Backspace,
    # Up/Down/`+`/`k`/`j`, PageUp/PageDown, Home/End).
    #
    # The including widget must provide:
    #
    #   * `#value` / `#value=` / `#step_up` / `#step_down` and `@minimum` /
    #     `@maximum` / `@step` — its numeric value/range logic (e.g. from
    #     `Mixin::RangedValue`);
    #   * `#parse_buffer(buf : String)` — parse the edit buffer to the widget's
    #     numeric type, returning `nil` on failure (`to_i?` / `to_f?`);
    #   * `#body_text : String` — the committed value as shown (e.g. `value.to_s`
    #     or a formatted string);
    #   * `#extra_entry_char?(ch : Char) : Bool` — whether *ch* is an accepted
    #     entry character beyond digits and a leading sign (e.g. a single `.`).
    #
    # It also wires the wheel/blur handlers by calling `#install_spinbox_editing`
    # from its own `#initialize`.
    module SpinBoxEditing
      # The in-progress edit buffer (`nil` when not editing). While editing, the
      # box shows this text instead of the committed value.
      @editing : String? = nil

      # Text shown before/after the number (Qt `QSpinBox#prefix`/`#suffix`).
      @prefix : String = ""
      @suffix : String = ""

      def prefix : String
        @prefix
      end

      # Sets the prefix, refreshing the displayed text on an actual change.
      def prefix=(v : String) : String
        return v if v == @prefix
        @prefix = v
        update_content
        v
      end

      def suffix : String
        @suffix
      end

      # Sets the suffix, refreshing the displayed text on an actual change.
      def suffix=(v : String) : String
        return v if v == @suffix
        @suffix = v
        update_content
        v
      end

      # Whether the value can be typed directly (Qt's `QAbstractSpinBox#readOnly`
      # inverted). When false the box only responds to stepping.
      property? editable : Bool = true

      # Qt's `QAbstractSpinBox#readOnly` — the exact inverse of `#editable?`.
      def read_only? : Bool
        !editable?
      end

      # :ditto:
      def read_only=(value : Bool) : Bool
        self.editable = !value
        value
      end

      # Refresh the displayed number whenever the value changes. Overrides
      # `RangedValue`'s no-op hook, so this mixin must be included *after*
      # `Mixin::RangedValue`.
      protected def on_value_changed
        update_content
      end

      # Shared spin-box `#initialize` tail: stores a non-inverted range and a
      # clamped `value` (`RangedValue#init_range` does the `maximum >= minimum`
      # fix-up an inverted range would otherwise leave `#value` stuck under),
      # wires key handling and the wheel/blur handlers, and paints the initial
      # content. Run it after `super`, and after any numeric formatting state the
      # widget needs for `#body_text` is set up.
      protected def setup_spinbox_editing(value, wrapping) : Nil
        @wrapping = wrapping
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
        on(Crysterm::Event::FocusOut) { cancel_edit if editing? }

        on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_up?
            # While `@editing` is non-nil the box shows the buffer, so a wheel step
            # would change the committed value invisibly. Discard the edit first,
            # matching `#stepping_key`.
            cancel_edit
            step_value_up
            e.accept
            request_render
          elsif e.action.wheel_down?
            cancel_edit
            step_value_down
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
          # A typed entry is an absolute value, not a step, so it must clamp
          # regardless of `#wrapping?`. On a wrapping box `#value=` alone would
          # treat an out-of-range value as a single-step overshoot and snap to the
          # *opposite* bound (typing 150 on a 0..100 wrap box would commit 0).
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
           # emptiness, not `@editing.nil?`: backspacing to empty leaves a
           # non-nil `""`, which must still accept `-`.
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
          stepping_key(e) { step_value_up }
        elsif k == ::Tput::Key::Down || ch == 'j'
          stepping_key(e) { step_value_down }
        elsif k == ::Tput::Key::PageUp
          stepping_key(e) { step_value_up page_step_delta(@step) }
        elsif k == ::Tput::Key::PageDown
          stepping_key(e) { step_value_down page_step_delta(@step) }
        elsif k == ::Tput::Key::Home
          stepping_key(e) { self.value = @minimum }
        elsif k == ::Tput::Key::End
          stepping_key(e) { self.value = @maximum }
        end
      end

      # The PageUp/PageDown delta: 10 line-steps, saturating to the numeric type's
      # own bound instead of raising when `step * 10` overflows.
      # `#step_up`/`#step_down` then saturate to the range bound as usual.
      private def page_step_delta(step : T) : T forall T
        step * 10
      rescue OverflowError
        step >= T.zero ? T::MAX : T::MIN
      end

      # Discards any in-progress edit buffer, runs the stepping *block*, then
      # accepts the event and repaints. Block-yielding, so it allocates no `Proc`.
      private def stepping_key(e, &) : Nil
        cancel_edit
        yield
        e.accept
        request_render
      end

      # Applies a buffer mutation (the *block* edits `@editing`), then refreshes
      # the displayed text, accepts the event and repaints — the display-side
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
