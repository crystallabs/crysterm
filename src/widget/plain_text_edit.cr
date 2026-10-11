require "./abstract_scroll_area"
require "../mixin/interactive"
require "../mixin/text_editing"

module Crysterm
  class Widget
    # Text area element, modeled after Qt's `QPlainTextEdit`.
    #
    # Derives `AbstractScrollArea` (Qt's `QPlainTextEdit < QAbstractScrollArea`,
    # not an input base) and mixes in `Mixin::Interactive` for the focus/keyboard
    # behavior that simpler controls get from `Input`. Text buffer/caret/wrapping/
    # key handling lives in `Mixin::TextEditing`, shared with `LineEdit` (an
    # `Input`, not a scroll area).
    #
    # Storage is a `TextDocument` via `Mixin::TextEditing::DocumentBuffer`, as in
    # Qt (`QPlainTextEdit` drives a `QTextDocument` with a plain layout), which is
    # what gives editing undo/redo (`C-z` / `M-z`). The document is plain (no rich
    # formats are entered), so rendering goes through the base content pipeline
    # (`@printable_content`), not `TextEdit`'s document paint path; `#value=` bridges the
    # document text back into `set_content`. The document is settable/shareable
    # between views, exactly like `TextEdit`.
    #
    # A line-number gutter — the `LineNumberArea` of Qt's code editor
    # example, built in here as a view property — shows with `#line_numbers =
    # true`: each source line's 1-based number sits right-aligned on the first
    # row of the line, a space before the text, and the rows a wrapped line
    # continues on stay blank. The gutter is as wide as the line count's
    # digits (two at least) plus the space, growing past 99 and 999 lines, and
    # the text re-wraps to the width left of it; the caret, mouse hit-testing,
    # selections and the horizontal scroll all count from the text's edge.
    # `Event::LineNumbersChanged` follows the toggle, for a View menu entry
    # bound to it (`Action#bind_checked`), and `PlainTextEdit::line-number {
    # color: … }` styles the digits — muted in the default theme, faded toward
    # the background with no stylesheet; the caret's line keeps the normal
    # foreground.
    #
    # ```
    # editor = Widget::PlainTextEdit.new parent: s, content: File.read(path)
    # editor.line_numbers = true
    # editor.highlight_current_line = true
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![PlainTextEdit screenshot](../../tests/widget/plaintextedit/plaintextedit.5s.apng)
    # <!-- /widget-examples:capture -->
    class PlainTextEdit < AbstractScrollArea
      include Mixin::Interactive
      include Mixin::TextEditing
      include Mixin::TextEditing::DocumentBuffer

      @scrollable = true

      # The read-only navigation keys apply (`Mixin::TextEditing#effective_key`).
      protected def read_only_navigation? : Bool
        true
      end

      # A pure viewport (see `TextEdit`): percent against the viewport span.
      @always_scroll = true
      # Plain text (Qt's `QPlainTextEdit`): the buffer is shown verbatim, so
      # braces the user types are literal, never markup.
      @parse_tags = false
      # Scroll source of truth is `@child_base` (top visible wrapped row); the
      # text caret (`@cursor_pos`) is tracked separately. Unlike `List`, where
      # `@child_offset` is the selected row, this widget keeps `@child_offset` at
      # 0, so `scroll_position == child_base` and the attached `ScrollBar` drives the
      # viewport top, matching Qt (dragging the bar moves the view, not the caret).
      @scrollbar_policy = ScrollBarPolicy::AsNeeded
      # Only engages with `wrap_content: false` (long lines run off the right
      # edge); `overflows_x?` is false while wrapping.
      @horizontal_scrollbar_policy = ScrollBarPolicy::AsNeeded

      # Last plain text pushed to the base content pipeline (`set_content`);
      # the display re-syncs only when the document text actually changed.
      # `nil` after a single-line patch, so the next full push never dedups
      # against a text the display no longer shows.
      @_display_value : String?

      # Whether the display reflects the document as it is now — true after a
      # full push and after each single-line patch, dropped by any document
      # change the patch can't take. Only a current display can be patched.
      @_display_fresh = false

      # Set by a single-line patch: the next frame follows the caret
      # (`_type_scroll`/`_update_cursor`) without pushing content.
      @_display_patched = false

      # Block count the display was built for; a single-block edit keeps it.
      @_display_blocks = 0

      # Columns the gutter reserves right now (`#line_number_area_width`),
      # 0 while `#line_numbers?` is off. Mirrored into `#viewport_margins`.
      @line_number_width = 0

      # Fewest digit columns the gutter shows, so it doesn't jitter between
      # 9 and 10 lines on a short document.
      LINE_NUMBER_MIN_DIGITS = 2

      # How far the gutter's foreground fades toward the background when no
      # `::line-number` rule styles it: the weight of the text color in the mix.
      LINE_NUMBER_FADE = 0.55

      def initialize(
        input_on_focus = false,
        max_length = nil,
        read_only = false,
        placeholder_text = nil,
        document : TextDocument? = nil,
        **input,
      )
        adopt_document document, input["content"]? || "", max_length, read_only

        super **(input.merge({keys: true}))

        placeholder_text.try { |v| @placeholder_text = v }

        finish_document_setup input_on_focus: input_on_focus, install_enter: !!input["keys"]?
      end

      # The document's plain text (Qt's `toPlainText`). A synonym for `#value` /
      # `Mixin::TextEditing#text`, spelled the way a `QPlainTextEdit` user
      # reaches for it.
      def to_plain_text : String
        value
      end

      # Replaces the whole text (Qt's `setPlainText`): the caret parks at the
      # end and the undo stack clears — this is a *reset*, not an undoable edit.
      # Use `#insert_text` / `#append_plain_text` for edits the user can undo.
      def plain_text=(text : String)
        self.value = text
      end

      # Appends *text* as new content at the end of the document (Qt's
      # `appendPlainText`), on its own paragraph when there is already text.
      # Unlike `#plain_text=` this is an ordinary, undoable document edit; the
      # caret is left at the end of the appended text.
      def append_plain_text(text : String) : Nil
        self.cursor_pos = buf_size
        clear_selection
        insert_text(buf_size.zero? ? text : "\n" + text)
      end

      protected def reset_document_caches : Nil
        @_display_value = nil
        @_display_fresh = false
        update_line_number_area_width
      end

      # Whether the line-number gutter is shown (see the class docs). Off by
      # default. Qt's `QPlainTextEdit` has no such property — its code editor
      # example composes the gutter from `setViewportMargins` and a child
      # widget — so this is Crysterm's own, as a view property that a menu
      # entry can toggle.
      getter? line_numbers : Bool = false

      # :ditto: — emits `Event::LineNumbersChanged` on an actual change. The
      # gutter's columns are reserved (or released) at once, so the next frame
      # already wraps the text to the new width.
      def line_numbers=(value : Bool) : Bool
        return value if value == @line_numbers
        @line_numbers = value
        update_line_number_area_width
        emit Crysterm::Event::LineNumbersChanged, value
        update
        update! if window?
        value
      end

      # Columns the gutter takes while shown — the digits of the line count
      # (`LINE_NUMBER_MIN_DIGITS` at least) plus the space before the text —
      # and 0 while hidden. The Qt example's `lineNumberAreaWidth()`.
      def line_number_area_width : Int32
        @line_number_width
      end

      # The gutter width *blocks* lines need; see `#line_number_area_width`.
      private def line_number_area_width_for(blocks : Int32) : Int32
        Math.max(decimal_digits(blocks), LINE_NUMBER_MIN_DIGITS) + 1
      end

      # Digits of *n* in base 10 (one for 0), without a `String`.
      private def decimal_digits(n : Int32) : Int32
        digits = 1
        while n >= 10
          n //= 10
          digits += 1
        end
        digits
      end

      # Re-reserves the gutter's columns from the current block count (the Qt
      # example's `updateLineNumberAreaWidth`, which it runs on
      # `blockCountChanged`). Called on the toggle, on every document change
      # and once per frame before the display syncs, so the wrap width the
      # frame lays out with already includes the gutter. A no-op while the
      # width is unchanged, which is every keystroke that keeps the digit
      # count.
      private def update_line_number_area_width : Nil
        w = @line_numbers ? line_number_area_width_for(document.block_count) : 0
        return if w == @line_number_width
        @line_number_width = w
        self.viewport_margins = w.zero? ? Padding::ZERO : Padding.left(w)
      end

      # Paints the gutter after the base render: the band is `#viewport_margins`
      # wide, left of the content and right of the border and padding, and the
      # base render already filled it with the widget's background. Each
      # wrapped row that starts a source line gets that line's number,
      # right-aligned before the gap column (`lineNumberAreaPaintEvent` of the
      # Qt example, walking `firstVisibleBlock` on); continuation rows and the
      # rows past the end stay blank. The caret's line keeps the widget's own
      # foreground, the others take `#line_number_attr`; a full-width extra
      # selection or the current-line tint on a row covers its gutter cells
      # too, so a highlighted row reads as one bar.
      private def paint_line_numbers : Nil
        lp = @lpos || return
        w = @line_number_width
        sb = style.border_view
        pd = style.padding_view
        # On a scroll-clipped left edge only the gutter's visible remainder is
        # on window (the same per-edge fit `base_render` applies), and that is
        # its right part: `hidden` leading columns of each number are cut.
        # The rulers' band (`AbstractScrollArea#rulers=`) is outside the
        # gutter's: a row above it and the row ruler's columns before it.
        rulers_left = @vertical_ruler_width
        rulers_top = @column_ruler ? 1 : 0
        ebl, epl = effective_edge_insets(sb.left, pd.left + rulers_left, lp.hidden_left)
        shown = effective_edge_insets(sb.left, pd.left + rulers_left + w, lp.hidden_left)[1] - epl
        return if shown <= 0
        hidden = w - shown
        x0 = lp.xi + ebl + epl
        ebt, ept = effective_edge_insets(sb.top, pd.top + rulers_top, lp.hidden_top)
        ebb, epb = effective_edge_insets(sb.bottom, pd.bottom, lp.hidden_bottom)
        yi = lp.yi + ebt + ept
        yl = lp.yl - ebb - epb - hscrollbar_rows

        rows = window.cell_rows
        base_attr = style_to_attr(style)
        dim_attr = line_number_attr(base_attr)
        current = document.block_at(@cursor_pos).index
        blocks = document.block_count
        wl = @wrapped_lines
        (yi...yl).each do |y|
          # A negative row index would count from the window's bottom.
          next if y < 0
          row = rows[y]? || break
          rl = lp.base + (y - yi)
          next if rl < 0 || rl >= wl.size
          fake = wl.rtof[rl]? || next
          # The placeholder's rows past its first carry no line.
          next if fake >= blocks
          next unless wl.ftor[fake]?.try(&.first?) == rl
          attr = fake == current ? base_attr : dim_attr
          if xfull = extra_selections_for_row(rl)[1]
            attr = xfull.apply_to_attr(attr)
          end
          paint_line_number row, x0, hidden, w, fake + 1, attr
        end
      end

      # Writes *number* into *row* over the gutter's visible columns
      # (`hidden...width` of the band, at *x0* on): the digits end right
      # before the gap column, blanks lead. No String is built — the digit for
      # a column is read off the number by place value.
      private def paint_line_number(row, x0 : Int32, hidden : Int32, width : Int32, number : Int32, attr : Int64) : Nil
        digits = decimal_digits(number)
        (hidden...width).each do |c|
          x = x0 + c - hidden
          next if x < 0
          cell = row[x]? || break
          place = width - 2 - c # 0 at the units digit, -1 at the gap column
          ch = place >= 0 && place < digits ? '0' + (number // 10 ** place) % 10 : ' '
          cell.set_if_changed(attr, ch)
        end
      end

      # The gutter's attr: the `::line-number` sub-style when a rule (or an
      # assignment) set it, else the widget's own colors with the foreground
      # faded toward the background by `LINE_NUMBER_FADE`, so the numbers
      # read as chrome under any plain stylesheet. (Terminal-default colors
      # can't be mixed; those stay as they are.)
      private def line_number_attr(base_attr : Int64) : Int64
        if sub = style.line_number?
          return style_to_attr(sub)
        end
        bg = Attr.bg(base_attr)
        Colors.blend(base_attr, Attr.pack(0_i64, bg, bg), alpha: LINE_NUMBER_FADE)
      end

      # The gutter over its band, in the chrome pass after the base render
      # (`AbstractScrollArea#paint_viewport_chrome`, before the rulers and
      # the guides).
      protected def paint_viewport_margins : Nil
        paint_line_numbers if @line_number_width > 0
      end

      # `Widget#extra_selections_for_row`: this widget paints through the
      # base renderer, which asks per row; the row's buffer bounds come from
      # the wrap map, as `#selection_columns_for_row` derives them.
      protected def extra_selections_for_row(rl : Int32) : Tuple(Array(Tuple(Range(Int32, Int32), TextCharFormat))?, TextCharFormat?)
        return {nil, nil} if (@extra_selections.empty? && !@highlight_current_line) || rl < 0 || rl >= @wrapped_lines.size
        row_extra_selections(pos_from_rowcol(rl, 0), pos_from_rowcol(rl, line_display_width(rl)), row_text_x_offset(rl))
      end

      # Re-syncs the shown text: with an empty document the placeholder *is*
      # the displayed content, and `#sync_display`'s dedup keys off the
      # document text alone, which a placeholder change leaves untouched.
      def placeholder_text=(value : String) : String
        return value if value == @placeholder_text
        @placeholder_text = value
        @_display_value = nil
        @_display_fresh = false
        sync_display
        update!
        value
      end

      private def wire_document : Nil
        @ev_contents_change = document.on(Crysterm::Event::ContentsChanged) do |e|
          # Mirror an edit made by another actor on a shared document onto this
          # view's caret (own edits are skipped — the mixin moves the caret
          # itself). An edit inside one block patches that line's rows right
          # here; anything else leaves the display to the next frame's full
          # push (`#sync_display`).
          follow_document_change(e.kind, e.position, e.chars_removed, e.chars_added)
          patch_display e.kind, e.position, e.chars_removed, e.chars_added
          update_line_number_area_width if @line_numbers
          update! if window?
        end
      end

      # Patches the displayed lines for an edit confined to one block, via
      # `Widget#replace_content_line`. Needs a display that is current, a
      # document that was and stays non-empty (an empty one shows the
      # placeholder through the full push), an unchanged block count, and an
      # inserted range that stays inside the block the edit started in. Any
      # other change marks the display stale for the full push.
      private def patch_display(kind : TextDocument::ChangeKind, pos : Int32, removed : Int32, added : Int32) : Nil
        fresh = @_display_fresh
        @_display_fresh = false
        return unless fresh && kind.edit?
        doc = document
        size = doc.size
        return if size == 0 || size - added + removed == 0
        return if doc.block_count != @_display_blocks
        block = doc.block_at(pos).index
        return if added > 0 && doc.block_at(pos + added).index != block
        return unless replace_content_line(block, doc.blocks[block].text)
        @_display_value = nil
        @_display_fresh = true
        @_display_patched = true
      end

      # Adds undo/redo on top of the shared editing keys.
      def _listener(e)
        return if handle_undo_redo_key(e)
        super
      end

      # External set: delegates to `DocumentBuffer#value=`, then pushes the
      # document's plain text into `set_content` (this widget renders through the
      # base `@printable_content` pipeline rather than the `ContentsChanged` paint).
      def value=(value : String)
        super
        sync_display
      end

      # Once-per-frame redisplay (from `#paint`): clamps the caret via
      # `DocumentBuffer#refresh_value`, then re-syncs `set_content` if it changed.
      def refresh_value : Nil
        super
        # Before the display syncs, so this frame's wrap width already holds
        # the gutter the current line count needs.
        update_line_number_area_width if @line_numbers
        sync_display
      end

      # Pushes the document's plain text into `set_content` whenever it changed
      # — unless the display is already current: untouched since the last
      # push, or patched line by line (then only the caret is followed). An
      # empty document with a `#placeholder_text` shows the placeholder
      # instead (Qt's `QPlainTextEdit#placeholderText`); the value stays empty.
      private def sync_display : Nil
        if @_display_fresh
          return unless @_display_patched
          @_display_patched = false
        else
          v = buf_text
          @_display_fresh = true
          @_display_blocks = document.block_count
          return if v == @_display_value
          @_display_value = v
          set_content(v.empty? && !@placeholder_text.empty? ? @placeholder_text : v)
        end
        _type_scroll
        _update_cursor
      end
    end
  end
end
