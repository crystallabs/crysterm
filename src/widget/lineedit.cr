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
      include Mixin::TextEditing::FlatBuffer

      # How the value is displayed, mirroring Qt's `QLineEdit::EchoMode`.
      enum EchoMode
        # Show the value as it is (the default).
        Normal
        # Show nothing at all, not even the value's length.
        NoEcho
        # Show one `#password_character` per user-perceived character.
        Password
        # `Normal` while the field is focused (i.e. while the user is editing),
        # `Password` the rest of the time.
        PasswordEchoOnEdit
      end

      # See `EchoMode`. Qt's `QLineEdit#echoMode`.
      property echo_mode : EchoMode = EchoMode::Normal

      # `#echo_mode` with `PasswordEchoOnEdit` resolved against the current focus
      # to the mode actually in force, so the display path only ever has to
      # handle the three concrete modes. Part of `#display_snapshot_key`, so
      # losing focus re-masks the field on the next frame.
      private def effective_echo_mode : EchoMode
        return EchoMode::Normal if @echo_mode.password_echo_on_edit? && focused?
        return EchoMode::Password if @echo_mode.password_echo_on_edit?
        @echo_mode
      end

      # Mask character shown for each hidden character in the `Password` echo
      # modes (Qt's `lineedit-password-character`). Defaults to `*`.
      property password_character : Char = '*'

      # Greyed-out prompt shown while the box is empty, like Qt's
      # `QLineEdit#placeholderText`. It is purely visual: `#value` stays empty.
      property placeholder_text : String = ""

      # Whether Up/Down walk the input history. On by default (shell-prompt
      # style); set false so the keys pass through for the host to navigate, e.g.
      # to move between form fields.
      property? history_keys : Bool = true

      # Submitted lines, oldest first — the input history walked by Up/Down
      # (like a shell prompt or Qt's editable combo). Public so an app can
      # pre-seed or inspect it.
      getter history = [] of String

      # Cursor into `@history`; `nil` is the sentinel "on the live line you're
      # typing" (Up steps back from the newest entry, Down returns here). Left
      # lazily `nil` rather than eagerly `history.size`, so a pre-seeded history
      # is reachable from the start; walkers resolve it as
      # `@history_pos || @history.size`.
      @history_pos : Int32? = nil
      # The half-typed line stashed on the first Up, restored when Down walks
      # back past the newest entry — so browsing history never loses your draft.
      @history_draft = ""

      def initialize(
        echo_mode : EchoMode? = nil,
        placeholder_text = nil,
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

        echo_mode.try { |v| @echo_mode = v }
        placeholder_text.try { |v| @placeholder_text = v }
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
        # the input history.
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
      # "dropped prefix" `#position_at`/`#selection_columns_for_row` measure from.
      @view_start : Int32 = 0

      # Snapshot of every input `#compute_display` reads, plus the resulting
      # `@view_start`. The build slices 3-5 intermediate strings (and, in the
      # `Password` modes, a fresh mask string) every call, and `#value=`'s
      # `@_value` guard dedups only `set_content`, not the build. `#value=` runs
      # once per frame, so at steady state this key is unchanged and the cached
      # string is returned untouched. `@value` is keyed by object identity + size:
      # a redisplay keeps the same String object, a genuine edit swaps it.
      @display_key : Tuple(UInt64, Int32, Int32, Int32, Int32, Int32, EchoMode, UInt64, Char, Bool)? = nil
      @display_cache : String = ""

      private def display_snapshot_key : Tuple(UInt64, Int32, Int32, Int32, Int32, Int32, EchoMode, UInt64, Char, Bool)
        {@value.object_id, @value.size, @cursor_pos, awidth, ihorizontal, @view_start,
         effective_echo_mode, @placeholder_text.object_id, @password_character, full_unicode?}
      end

      def value=(value = nil)
        # Shared prologue (authoritative value + caret + selection); a non-nil
        # argument is an external set (cursor to the end), `nil` a redisplay that
        # preserves the cursor. The block strips newlines — this is single-line —
        # on both paths. `assign_value` must record the value *before* the display
        # dedup guard, or a stale `@_value` cache would no-op an external set like
        # `input.value = ""` and leave stale text across submits.
        assign_value(value) { |v| v.includes?('\n') ? v.delete('\n') : v }

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
        key = display_snapshot_key
        return @display_cache if key == @display_key

        mode = effective_echo_mode
        disp =
          if @value.empty? && !@placeholder_text.empty?
            # Show the placeholder while empty; the real value stays "".
            @view_start = 0
            @placeholder_text
          elsif mode.no_echo?
            @view_start = 0
            ""
          elsif mode.password?
            # One mask char per user-perceived character (grapheme) under
            # full_unicode; per codepoint otherwise. Count graphemes without
            # materializing the array, and build the mask without a `.to_s`
            # intermediate.
            @view_start = 0
            n = full_unicode? ? grapheme_count(@value) : @value.size
            String.build(n) { |io| n.times { io << @password_character } }
          else
            val = expanded_value
            # Visible width (`awidth - ihorizontal - 1`; -1 leaves room for the caret).
            # `cols` is a *display*-column budget.
            cols = Math.max 0, awidth - ihorizontal - 1
            # `@view_start` is a codepoint index into `val`, but the slide must be
            # measured in *display* columns so wide (CJK/emoji) glyphs count as 2;
            # a codepoint index against a column budget under-scrolls and leaves
            # the caret off-screen. `column_index` converts back for the slice.
            caret_cp = expanded_width(@value[0...@cursor_pos.clamp(0, @value.size)])
            caret_col = str_width val, 0, caret_cp
            view_col = str_width val, 0, @view_start
            # Slide the window to keep the caret inside `[view_col, view_col+cols]`.
            if caret_col < view_col
              @view_start = caret_cp
            elsif caret_col > view_col + cols
              @view_start = column_index(val, caret_col - cols)
            end
            # Clamp so we never scroll past the value's end (showing the tail when
            # the caret sits there).
            @view_start = @view_start.clamp(0, column_index(val, Math.max(0, str_width(val) - cols)))

            window = val[@view_start..]
            # Leading graphemes/codepoints of the window that fit `cols` display
            # columns (`column_index` is codepoint-unit under the legacy path).
            window[0, column_index(window, cols)]
          end

        # Re-key with the settled `@view_start` so the next steady-state frame
        # (same value/caret/dims, window already at its fixpoint) hits the cache.
        @display_key = display_snapshot_key
        @display_cache = disp
        disp
      end

      # Codepoint-range display width of `val` without slicing it first. The
      # common path (no SGR, legacy codepoint counting) is a plain subtraction;
      # SGR-carrying or `full_unicode?` values fall back to the slice+measure
      # `str_width` overload (rare for a single-line input's own text).
      private def str_width(val : String, from : Int32, to : Int32) : Int32
        from = from.clamp(0, val.size)
        to = to.clamp(0, val.size)
        return 0 if to <= from
        return str_width(val[from...to]) if full_unicode? || val.includes?('\e')
        to - from
      end

      # Grapheme-cluster count of `s` without allocating the `graphemes` array.
      private def grapheme_count(s : String) : Int32
        n = 0
        s.each_grapheme { n += 1 }
        n
      end

      def submit
        @__listener.try &.call Crysterm::Event::KeyPress.new '\r', Tput::Key::Enter
      end

      # The visible line is a re-sliced *tail* of `@value` (`@_value`), so
      # selection columns must be measured from the first visible `@value` index,
      # not from the logical line start the generic (`@child_base_x`-based)
      # version assumes. Highlight is suppressed in every non-`Normal` echo mode:
      # a masked field's selection shouldn't be visually revealed.
      protected def selection_columns_for_row(rl : Int32) : Range(Int32, Int32)?
        return nil unless rl == 0
        return nil unless effective_echo_mode.normal?
        return nil unless range = selection_range

        # First and last `@value` indices actually shown, mapped back from the
        # `@_value` window. The window can be scrolled left of the value's end,
        # so *both* ends of the selection can fall off-view.
        vis_start = unexpand_col(@value, @view_start)
        vis_end = unexpand_col(@value, @view_start + @_value.size)

        lo = Math.max(range.begin, vis_start)
        hi = Math.min(range.end, vis_end)
        return nil if lo >= hi

        col_lo = rendered_column(vis_start, lo)
        col_hi = rendered_column(vis_start, hi)
        col_lo...col_hi
      end

      # The single visible line (`@_value`) is a re-sliced tail of `@value`, not
      # the `@_clines`/`@child_base_x` viewport slice the generic mixin version
      # assumes — which would map a click to the wrong `@value` index whenever
      # the field is scrolled.
      def position_at(x : Int32, y : Int32) : Int32
        return 0 if @value.empty?
        mode = effective_echo_mode
        # `NoEcho` shows nothing to click onto; park at the end, matching how the
        # field is fully obscured.
        return @value.size if mode.no_echo?

        lpos = coords
        return cursor_pos unless lpos

        left = lpos.xi + ileft
        disp_idx = column_index(@_value, (x - left).clamp(0, content_width))

        if mode.password?
          # `@_value` is one mask char per grapheme of `@value`, so `disp_idx` is
          # already a grapheme count; walk that many to get a codepoint offset.
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
          # starting at `@view_start` expanded columns; offset the click's index
          # by that dropped prefix, then undo the tab expansion.
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

      # Caret's *display* column within the shown window (see `#compute_display`).
      # `0` under `NoEcho` (nothing shown);
      # grapheme/codepoint count before the caret under `Password` (the mask
      # isn't windowed). Measured with `str_width` so a wide glyph before the
      # caret advances the column by 2, keeping the caret off-by drift-free.
      private def caret_view_col : Int32
        mode = effective_echo_mode
        return 0 if mode.no_echo?
        if mode.password?
          cp = @cursor_pos.clamp(0, @value.size)
          # Legacy (codepoint) path is just the clamped caret index — no slice.
          return cp unless full_unicode?
          return grapheme_count(@value[0...cp])
        end
        val = expanded_value
        caret_cp = expanded_width(@value[0...@cursor_pos.clamp(0, @value.size)])
        return 0 if caret_cp <= @view_start
        str_width val, @view_start, caret_cp
      end

      # Places the caret at its column within the `#compute_display` window,
      # clamped into the viewport (the trailing `content_width` column is
      # reserved for an end-of-line caret). The inherited version maps
      # `@cursor_pos` onto `@_clines` — here only the re-sliced window — so it
      # would clamp the caret to the window's end instead of the real edit point.
      def _update_cursor(get = false, to_scroll_pos = false)
        return unless focused?

        lpos = get ? @lpos : coords
        return unless lpos

        display = window
        left = lpos.xi + ileft
        cy = lpos.yi + itop
        cx = (left + caret_view_col).clamp(left, left + Math.max(0, content_width))

        move_terminal_caret display, cx, cy
      end

      # Reports whether the caret sits outside the `@view_start` window (this is
      # not a scroll area; it scrolls that window instead), so a caret move
      # needing a scroll flags `scrolled` and triggers a render. The window shift
      # itself happens in `#compute_display` on that render.
      private def ensure_cursor_visible_x : Bool
        # Only `Normal` windows the value; the masked modes render unwindowed.
        return false unless effective_echo_mode.normal?
        # Compare in display columns (matching `#compute_display`), so a wide
        # glyph pushing the caret past the visible width still flags a scroll.
        cols = Math.max 0, awidth - ihorizontal - 1
        val = expanded_value
        caret_cp = expanded_width(@value[0...@cursor_pos.clamp(0, @value.size)])
        caret_col = str_width val, 0, caret_cp
        view_col = str_width val, 0, @view_start
        caret_col < view_col || caret_col > view_col + cols
      end
    end
  end
end
