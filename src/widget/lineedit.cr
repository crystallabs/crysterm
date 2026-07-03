require "./input"
require "../mixin/text_editing"

module Crysterm
  class Widget
    # Single-line text entry, modeled after Qt's `QLineEdit`.
    #
    # Qt's `QLineEdit < QWidget` — *not* a scroll area like `QPlainTextEdit`. So
    # `LineEdit` derives `Input` (Crysterm's interactive intermediate, the same
    # base `Button` uses) and includes `Mixin::TextEditing` for the shared text
    # buffer/caret/key handling, rather than inheriting `PlainTextEdit`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![LineEdit screenshot](../../tests/widget/lineedit/lineedit.5s.apng)
    # <!-- /widget-examples:capture -->
    class LineEdit < Input
      include Mixin::TextEditing

      property secret : Bool = false
      property censor : Bool = false

      # Mask character shown for each hidden character when `censor` is on
      # (Qt's `lineedit-password-character`). Defaults to `*`.
      property password_character : Char = '*'

      # Greyed-out prompt shown while the box is empty, like Qt's
      # `QLineEdit#placeholderText`. It is purely visual: `#value` stays empty.
      property placeholder : String = ""

      # Whether Up/Down walk the input history. On by default (shell-prompt
      # style); a form field that wants Up/Down to move between fields sets this
      # false so the keys pass through for the host/screen to navigate.
      property? history_keys : Bool = true

      # Submitted lines, oldest first — the input history walked by Up/Down
      # (like a shell prompt or Qt's editable combo). Public so an app can
      # pre-seed or inspect it.
      getter history = [] of String

      # Cursor into `@history`; `nil` is the sentinel "on the live line you're
      # typing" (Up steps back from the newest entry, Down returns here). Kept
      # lazily as `nil` rather than eagerly set to `history.size`, so a
      # pre-seeded history is reachable from the start (resolve as
      # `@history_pos || @history.size` at each walker).
      @history_pos : Int32? = nil
      # The half-typed line stashed on the first Up, restored when Down walks
      # back past the newest entry — so browsing history never loses your draft.
      @history_draft = ""

      def initialize(
        secret = nil,
        censor = nil,
        placeholder = nil,
        parse_tags = false,
        input_on_focus = true,
        max_length = nil,
        read_only = false,
        scrollable = false,
        **input,
      )
        setup_text_buffer(input["content"]? || "", max_length, read_only)

        super **input.merge({parse_tags: parse_tags, scrollable: scrollable, keys: true})

        setup_text_editing input_on_focus: input_on_focus, install_enter: !!input["keys"]?

        secret.try { |v| @secret = v }
        censor.try { |v| @censor = v }
        placeholder.try { |v| @placeholder = v }
      end

      def _listener(e : Crysterm::Event::KeyPress)
        if e.key == Tput::Key::Enter
          e.accept
          # A non-kill action breaks the consecutive-kill run (emacs semantics);
          # the mixin's `super` normally does this, but these keys return early.
          kill_ring.interrupt if Crysterm::Config.input_readline_keys
          record_history @value
          @_done.try do |done2|
            done2.call @value
          end
          return
        end
        # Single-line, so Up/Down can't move between rows — repurposed to walk
        # the input history. A form wanting Up/Down to move between fields turns
        # this off (`history_keys = false`), letting the keys fall through.
        if history_keys?
          if e.key == Tput::Key::Up
            e.accept
            kill_ring.interrupt if Crysterm::Config.input_readline_keys
            history_prev
            return
          end
          if e.key == Tput::Key::Down
            e.accept
            kill_ring.interrupt if Crysterm::Config.input_readline_keys
            history_next
            return
          end
        end
        super
      end

      # Append a just-submitted line to the history and reset the cursor to the
      # live line. Blank lines and an immediate repeat of the last entry are
      # skipped (shell `ignoredups`), so Up gives back meaningful commands.
      private def record_history(line)
        @history_pos = nil
        @history_draft = ""
        return if line.empty?
        return if !@history.empty? && @history.last == line
        @history << line
      end

      # Up: recall an older entry. On the first step off the live line, stash the
      # draft so Down can bring it back.
      private def history_prev
        return if @history.empty?
        # `nil` (live line) resolves to the sentinel `history.size`.
        pos = @history_pos || @history.size
        return if pos == 0
        @history_draft = @value if pos == @history.size
        pos -= 1
        @history_pos = pos
        # A non-nil `value=` is an external set, which parks the cursor at the end.
        self.value = @history[pos]
      end

      # Down: recall a newer entry, or step back onto the stashed draft once you
      # walk past the newest entry.
      private def history_next
        pos = @history_pos || @history.size
        return if pos >= @history.size
        pos += 1
        if pos == @history.size
          @history_pos = nil
          self.value = @history_draft
        else
          @history_pos = pos
          self.value = @history[pos]
        end
      end

      # Expanded-codepoint index of the first content column currently shown —
      # the left edge of the horizontal window `#compute_display` slices. `0`
      # while the value fits; grows as the caret moves past the right edge and
      # shrinks (down to `0`) as it moves back toward the start, so the edit
      # point stays visible even when the value overflows the box. This is the
      # "dropped prefix" `#position_at`/`#selection_columns_for_row` measure
      # from; it replaces the old "tail of the whole value" assumption.
      @view_start : Int32 = 0

      def value=(value = nil)
        # Shared prologue (authoritative-value + caret + selection); a non-nil
        # argument is an external set (cursor to the end), `nil` a redisplay that
        # preserves the cursor (see `PlainTextEdit#value=`). The block strips
        # newlines — this is single-line — on both paths, as before. `_listener`
        # mutates `@value` directly, so `assign_value` recording it before the
        # display dedup guard is what keeps an external set like `input.value =
        # ""` from being no-op'd (and leaving stale text across submits) when the
        # `@_value` last-displayed cache is stale.
        assign_value(value, &.delete('\n'))

        # `@_value` caches the *displayed* text so the dedup guard also fires
        # the first time an empty box needs to paint its placeholder.
        disp = compute_display
        if @_value != disp
          @_value = disp
          set_content disp
          _update_cursor
        end
      end

      # Computes the string actually shown, scrolling the `@view_start` window so
      # the caret stays visible when the value is wider than the box. Called from
      # `#value=` (and thus once per frame via `Mixin::TextEditing#render`), so
      # the window re-tracks the caret every render.
      private def compute_display : String
        if @value.empty? && !@placeholder.empty?
          # Show the placeholder while empty; the real value stays "".
          @view_start = 0
          @placeholder
        elsif @secret
          @view_start = 0
          ""
        elsif @censor
          # One mask char per user-perceived character (grapheme) under
          # full_unicode; per codepoint otherwise.
          @view_start = 0
          @password_character.to_s * (full_unicode? ? @value.graphemes.size : @value.size)
        else
          val = expanded_value
          # Visible width (`awidth - iwidth - 1`; -1 leaves room for the caret).
          # `cols` is a *display*-column budget.
          cols = Math.max 0, awidth - iwidth - 1
          # `@view_start` is a codepoint index into `val`; measure the slide in
          # *display* columns so wide (CJK/emoji) glyphs count as 2. Mixing the
          # codepoint index against a display-column budget would leave the caret
          # off-screen for wide content (`caret_cp - cols` under-scrolls). Convert
          # back to a codepoint index via `column_index` for the actual slice.
          caret_cp = expanded_width(@value[0...@cursor_pos.clamp(0, @value.size)])
          caret_col = str_width val[0, caret_cp]
          view_col = str_width val[0, @view_start]
          # Slide the window to keep the caret inside `[view_col, view_col+cols]`.
          if caret_col < view_col
            @view_start = caret_cp
          elsif caret_col > view_col + cols
            @view_start = column_index(val, caret_col - cols)
          end
          # Clamp so we never scroll past the value's end (showing the tail when
          # the caret sits there, the previous unconditional behavior).
          @view_start = @view_start.clamp(0, column_index(val, Math.max(0, str_width(val) - cols)))

          window = val[@view_start..]
          # Leading graphemes/codepoints of the window that fit `cols` display
          # columns (`column_index` is codepoint-unit under the legacy path).
          window[0, column_index(window, cols)]
        end
      end

      def submit
        @__listener.try &.call Crysterm::Event::KeyPress.new '\r', Tput::Key::Enter
      end

      # Overrides `Mixin::TextEditing#selection_columns_for_row` for the same
      # reason `#position_at` is overridden: the visible line is a re-sliced
      # *tail* of `@value` (`@_value`), so selection columns must be measured
      # from the first visible `@value` index, not from the logical line start
      # the generic (`@child_base_x`-based) version assumes. Highlight is
      # suppressed in `secret`/`censor` modes (nothing meaningful to mark, and
      # a masked field's selection shouldn't be visually revealed anyway).
      protected def selection_columns_for_row(rl : Int32) : Range(Int32, Int32)?
        return nil unless rl == 0
        return nil if @secret || @censor
        return nil unless range = selection_range

        # First and last `@value` indices actually shown. `@_value` is a window
        # of the tab-expanded value starting at `@view_start` expanded columns
        # (see `#compute_display`); map both edges back to raw `@value` indices.
        # Unlike the old tail-only slice, the window can now be scrolled left of
        # the value's end, so *both* ends of the selection can fall off-view.
        vis_start = unexpand_col(@value, @view_start)
        vis_end = unexpand_col(@value, @view_start + @_value.size)

        lo = Math.max(range.begin, vis_start)
        hi = Math.min(range.end, vis_end)
        return nil if lo >= hi

        col_lo = rendered_column(vis_start, lo)
        col_hi = rendered_column(vis_start, hi)
        col_lo...col_hi
      end

      # Overrides `Mixin::TextEditing#position_at`: `LineEdit`'s single visible
      # line (`@_value`) is `value=`'s own re-sliced tail of `@value` (see
      # `#value=`), not a `@_clines`/`@child_base_x` viewport slice — the
      # generic mixin version assumes the latter, so it would map a click to
      # the wrong `@value` index whenever the field is scrolled (i.e. its
      # content overflows the box).
      def position_at(x : Int32, y : Int32) : Int32
        return 0 if @value.empty?
        # Secret mode shows nothing to click onto; park at the end, matching
        # how the field is fully obscured.
        return @value.size if @secret

        lpos = _get_coords
        return cursor_pos unless lpos

        left = lpos.xi + ileft
        disp_idx = column_index(@_value, (x - left).clamp(0, content_width))

        if @censor
          # `@_value` is one mask char per grapheme of `@value` (see
          # `#value=`) — `disp_idx` is already a grapheme count; convert to a
          # codepoint offset by walking that many graphemes.
          if full_unicode?
            offset = 0
            seen = 0
            @value.each_grapheme do |g|
              break if seen >= disp_idx
              offset += g.to_s.size
              seen += 1
            end
            offset
          else
            disp_idx
          end
        else
          # `@_value` is the tab-expanded window of `@value` actually shown,
          # starting at `@view_start` expanded columns (see `#compute_display`).
          # Offset the click's index within the window by that dropped prefix,
          # then undo the tab expansion to land on a raw `@value` index.
          unexpand_col(@value, @view_start + disp_idx)
        end
      end

      # The tab-expanded value as shown by `#compute_display` (`@view_start` and
      # the caret indices are codepoint offsets into this).
      private def expanded_value : String
        # No tabs ⇒ the value is already its own expansion; skip the scan/alloc
        # (this runs several times per frame per visible field).
        return @value unless @value.includes?('\t')
        @value.gsub('\t', style.tab_char * style.tab_size)
      end

      # Caret's *display* column within the shown window (see `#compute_display`),
      # used by `#_update_cursor`. `0` in secret mode (nothing shown);
      # grapheme/codepoint count before the caret in censor mode (the mask isn't
      # windowed). Measured with `str_width` so a wide glyph before the caret
      # advances the column by 2, keeping the caret off-by drift-free.
      private def caret_view_col : Int32
        return 0 if @secret
        if @censor
          before = @value[0...@cursor_pos.clamp(0, @value.size)]
          return full_unicode? ? before.graphemes.size : before.size
        end
        val = expanded_value
        caret_cp = expanded_width(@value[0...@cursor_pos.clamp(0, @value.size)])
        return 0 if caret_cp <= @view_start
        str_width val[@view_start...caret_cp]
      end

      # Overrides `Mixin::TextEditing#_update_cursor`: the inherited version maps
      # `@cursor_pos` onto `@_clines`, which for `LineEdit` is only the re-sliced
      # window (`#compute_display`) — so it clamps the caret to the window's end
      # instead of tracking the real edit point. Place the caret at its column
      # within that window instead, clamped into the viewport (the trailing
      # `content_width` column is reserved for an end-of-line caret).
      def _update_cursor(get = false, to_scroll_pos = false)
        return unless focused?

        lpos = get ? @lpos : _get_coords
        return unless lpos

        display = window
        left = lpos.xi + ileft
        cy = lpos.yi + itop
        cx = (left + caret_view_col).clamp(left, left + Math.max(0, content_width))

        move_terminal_caret display, cx, cy
      end

      # Overrides the mixin's `#ensure_cursor_visible_x` (a no-op while not a
      # scroll area, which `LineEdit` isn't — it scrolls a `@view_start` window
      # instead). Reports whether the caret currently sits outside that window,
      # so a caret move that needs to scroll flags `scrolled` in the key handler
      # and triggers a render; the actual window shift is done by
      # `#compute_display` on that render.
      private def ensure_cursor_visible_x : Bool
        return false if @secret || @censor
        # Compare in display columns (matching `#compute_display`), so a wide
        # glyph pushing the caret past the visible width still flags a scroll.
        cols = Math.max 0, awidth - iwidth - 1
        val = expanded_value
        caret_cp = expanded_width(@value[0...@cursor_pos.clamp(0, @value.size)])
        caret_col = str_width val[0, caret_cp]
        view_col = str_width val[0, @view_start]
        caret_col < view_col || caret_col > view_col + cols
      end
    end
  end
end
