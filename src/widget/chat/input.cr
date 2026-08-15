require "../../chat/glyphs"
require "../../mixin/input_history"
require "../plain_text_edit"

module Crysterm
  class Widget
    module Chat
      # The chat input line: a multiline `PlainTextEdit` dressed as a
      # Claude-CLI-style prompt — rounded border, a `❯` chevron in a
      # 2-column left gutter, placeholder text while empty — with
      # submit-on-Enter semantics and a shell-style input history.
      #
      # ### Keys
      #
      # * `Enter` submits: emits `Event::Submitted` with the full text, records
      #   it in `#history` and clears the buffer. Blank text is a no-op.
      # * `Shift+Enter` (enhanced keyboard protocols only — legacy terminals
      #   cannot distinguish it) inserts a newline.
      # * `\` + `Enter` replaces the backslash with a newline — the
      #   legacy-terminal spelling of Shift+Enter.
      # * `Up`/`Down` walk the history, but only when the caret is on the
      #   first/last line of the buffer; on any other line they move the caret,
      #   so intra-buffer navigation and history recall coexist (`Down` past
      #   the newest entry restores the draft stashed by the first `Up`).
      #
      # Unlike `LineEdit#submit` (which finishes the `read_input` session),
      # submitting here leaves the editing session running: a chat prompt is
      # persistent, so Enter hands off the text and keeps the focus/caret
      # where they are. Subscribe to `Event::Submitted` rather than using the
      # `read_input(&callback)` completion.
      #
      # ### Geometry
      #
      # The widget auto-grows: its height tracks the buffer's line count
      # (plus border/padding), clamped to `#max_height` (default 8 total
      # rows), beyond which the interior scrolls. Passing an explicit
      # `height:` disables the auto-growth (or set `auto_grow` yourself).
      # Anchor with `bottom:` so growth extends upward, transcript-style.
      class Input < PlainTextEdit
        # Shell-style Up/Down input history (`#history`, `#history_keys?`,
        # `#record_history`/`#history_prev`/`#history_next`); the Up/Down key
        # arms below add the caret-on-first/last-line gate before walking it.
        include Mixin::InputHistory

        # Glyph painted in the left gutter (first content row). Styled via the
        # `prefix` sub-style (falls back to the widget style).
        property prompt : String = ::Crysterm::Chat::Glyphs::PROMPT

        # Greyed-out prompt shown while the buffer is empty, like
        # `LineEdit#placeholder_text`. Purely visual: `#value` stays empty.
        property placeholder_text : String = ""

        # Whether the widget resizes itself to the buffer's line count (see
        # the class docs). Defaults to true unless an explicit `height:` was
        # given at construction.
        property? auto_grow : Bool = true

        # Whether the placeholder is what is currently pushed to the display.
        @_placeholder_shown = false

        # `style_to_attr` memo for the per-frame prompt stamp (`style.prefix`):
        # `#paint_prompt` runs on every render with an unchanged sub-style, so
        # the attr derivation is skipped until that slot's style is mutated or
        # swapped.
        @prefix_attr_memo = Style::AttrMemo.new

        def initialize(
          placeholder_text : String? = nil,
          prompt : String? = nil,
          history_keys : Bool = true,
          auto_grow : Bool? = nil,
          max_height : Int32? = 8,
          input_on_focus = true,
          **input,
        )
          super **input, input_on_focus: input_on_focus

          # Default chrome, unless the caller styled the widget wholesale:
          # the rounded input border and the 2-column prompt gutter (left
          # padding), which `#paint_prompt` stamps the chevron into.
          if input["style"]?.nil?
            st = state_style
            st.border = BorderType::Rounded
            st.padding = Padding.new 2, 0, 0, 0
            invalidate_frame_style
          end

          placeholder_text.try { |v| @placeholder_text = v }
          prompt.try { |v| @prompt = v }
          @history_keys = history_keys
          self.max_height = max_height
          # An explicit `height:` means the caller owns the geometry.
          @auto_grow = auto_grow.nil? ? input["height"]?.nil? : auto_grow

          sync_height if @auto_grow
        end

        def _listener(e)
          if e.key == Tput::Key::Enter && !e.shift?
            e.accept
            if !read_only? && @cursor_pos > 0 && buf_char(@cursor_pos - 1) == '\\'
              escape_newline
            else
              submit
            end
            return
          end

          if history_keys? && (k = e.key)
            if k == Tput::Key::Up && caret_on_first_line?
              e.accept
              kill_ring.interrupt if Crysterm::Config.input_readline_keys
              history_prev
              return
            end
            if k == Tput::Key::Down && caret_on_last_line?
              e.accept
              kill_ring.interrupt if Crysterm::Config.input_readline_keys
              history_next
              return
            end
          end

          super
        end

        # Submits the buffer: records it in the history, clears, and emits
        # `Event::Submitted` with the text. Blank (empty/whitespace-only) text
        # is a no-op. Does NOT finish an active `read_input` session — the
        # chat prompt stays live across submissions (see the class docs).
        def submit
          kill_ring.interrupt if Crysterm::Config.input_readline_keys
          text = value
          return if text.blank?
          record_history text
          self.value = ""
          emit Crysterm::Event::Submitted, text
        end

        def paint(with_children = true)
          sync_height if auto_grow?
          ret = super
          paint_prompt if ret
          ret
        end

        # Once-per-frame redisplay: after the document→display sync, swap the
        # placeholder in/out of the display when the buffer is empty.
        def refresh_value : Nil
          super
          apply_placeholder
        end

        # `\` + Enter: consume the backslash and insert the newline it escaped,
        # as one undo step.
        private def escape_newline : Nil
          buf_edit_group do
            buf_delete(@cursor_pos - 1, @cursor_pos)
            @cursor_pos -= 1
            insert_at_cursor "\n"
          end
          ensure_cursor_visible
          emit Crysterm::Event::TextChanged, value if text_change_observed?
          update!
        end

        # Whether no newline precedes the caret (caret on the buffer's first
        # logical line — where Up means "recall older").
        private def caret_on_first_line? : Bool
          nl = value.index '\n'
          nl.nil? || @cursor_pos <= nl
        end

        # Whether no newline follows the caret (caret on the buffer's last
        # logical line — where Down means "recall newer").
        private def caret_on_last_line? : Bool
          nl = value.rindex '\n'
          nl.nil? || @cursor_pos > nl
        end

        # The border-box height the buffer wants: one row per logical line
        # plus the vertical insets, at least one content row, capped at
        # `#max_height` (past which the interior scrolls). The line count is
        # the document's `block_count` — O(1) where scanning `value` is O(n)
        # per frame, and exactly `value.count('\n') + 1`: blocks join with
        # `'\n'`, and an empty document is one empty block.
        private def desired_height : Int32
          h = document.block_count + ivertical
          min = 1 + ivertical
          h = min if h < min
          # `resolved_max_height`, not the raw `#max_height` spec: the cap may
          # be a percentage of the parent, and this needs a cell count.
          resolved_max_height.try { |mh| h = mh if h > mh }
          h
        end

        private def sync_height : Nil
          # `height=` is change-guarded, so a steady-state frame is a no-op.
          self.height = desired_height
        end

        # Stamps `#prompt` into the left padding gutter on the first content
        # row, in the `prefix` sub-style. Skipped when the resolved style
        # leaves no gutter (zero left padding).
        private def paint_prompt : Nil
          lpos = @lpos
          return unless lpos
          st = style
          gutter = st.padding.left
          return if gutter < 1
          x = lpos.xi + ileft - gutter
          y = lpos.yi + itop
          draw_text_run y, x, @prompt, x + gutter, @prefix_attr_memo.fetch(st.prefix)
        end

        # Swaps the placeholder into the display while the buffer is empty
        # (and back out when it no longer is). The buffer↔display dedup in
        # `PlainTextEdit#sync_display` keys on the *buffer* text, so pushing
        # the placeholder here does not disturb it: the first real edit
        # re-pushes the buffer text as usual.
        private def apply_placeholder : Nil
          return if @placeholder_text.empty?
          if buf_size.zero?
            unless @_placeholder_shown
              @_placeholder_shown = true
              set_content @placeholder_text
            end
          else
            @_placeholder_shown = false
          end
        end
      end
    end
  end
end
