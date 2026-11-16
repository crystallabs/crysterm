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
    # The line-number gutter every scroll area has
    # (`AbstractScrollArea#line_numbers=`) numbers the source lines here, as
    # in Qt's code editor example: each line's 1-based number sits
    # right-aligned on the first row of the line, a space before the text,
    # and the rows a wrapped line continues on stay blank. The caret's line
    # keeps the normal foreground.
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

        # `Escape` is not this widget's to consume (Qt's text edits ignore
        # it): the pane keeps the focus and the key goes on to the window.
        @escape_cancels = false
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
        sync_line_number_width
      end

      # The gutter numbers the source lines (`AbstractScrollArea#line_numbers=`),
      # so its width follows the line count — known from the document, ahead
      # of any layout.
      protected def line_number_count : Int32
        document.block_count
      end

      # A source line's number on the row it starts on; its continuation
      # rows, and the placeholder's rows past its first, stay blank.
      protected def line_number_at(rl : Int32) : Int32
        wl = @wrapped_lines
        return 0 if rl < 0 || rl >= wl.size
        fake = wl.rtof[rl]? || return 0
        return 0 if fake >= document.block_count
        wl.ftor[fake]?.try(&.first?) == rl ? fake + 1 : 0
      end

      # The caret's source line.
      protected def current_line_number : Int32
        document.block_at(@cursor_pos).index + 1
      end

      # A full-width extra selection on the row (the current line's tint)
      # covers the gutter's and the row ruler's cells too — on the rows the
      # gutter paints, a wrapped line's first; its continuation rows stay as
      # they are, as the gutter's do.
      protected def chrome_row_attr(rl : Int32, attr : Int64) : Int64
        wl = @wrapped_lines
        fake = wl.rtof[rl]? || return attr
        return attr unless wl.ftor[fake]?.try(&.first?) == rl
        if xfull = extra_selections_for_row(rl)[1]
          xfull.apply_to_attr(attr)
        else
          attr
        end
      end

      # `Widget#extra_selections_for_row`: this widget paints through the
      # base renderer, which asks per row; the row's buffer bounds come from
      # the wrap map, as `#selection_columns_for_row` derives them.
      protected def extra_selections_for_row(rl : Int32) : Tuple(Array(Tuple(Range(Int32, Int32), TextCharFormat))?, TextCharFormat?)
        return {nil, nil} if (@extra_selections.empty? && !@highlight_current_line) || rl < 0 || rl >= @wrapped_lines.size
        row_start, row_end = row_buffer_bounds rl
        row_extra_selections(row_start, row_end, row_text_x_offset(rl))
      end

      # What `#row_buffer_bounds` last worked out: the row, its logical line,
      # the column the row starts at within it, that line's buffer bounds and
      # whether it holds a TAB — and the wrap all of it was measured against
      # (content version, wrap width, row count). Dropped at the start of
      # every frame.
      @_row_rl = -1
      @_row_fake = -1
      @_row_prefix = 0
      @_row_line = {0, 0}
      @_row_tabs = false
      @_row_wrap = {-1_i64, -1, -1}

      # Buffer positions of row *rl*'s start and end — `pos_from_rowcol(rl,
      # 0)` and `pos_from_rowcol(rl, line_display_width(rl))`. Rows are
      # painted top to bottom, so a row's start column within its logical
      # line follows from the previous row's, and the line's bounds and TAB
      # scan are shared by its rows; working each out afresh for every row
      # would make one long wrapped paragraph quadratic in its rows.
      private def row_buffer_bounds(rl : Int32) : Tuple(Int32, Int32)
        wl = @wrapped_lines
        fake = wl.rtof[rl]? || 0
        wrap = {wl.content_version, wl.width, wl.size}
        reals = wl.ftor[fake]?
        prefix = nil
        if fake == @_row_fake && wrap == @_row_wrap
          if rl == @_row_rl
            prefix = @_row_prefix
          elsif rl == @_row_rl + 1 && reals && !reals.empty? &&
                reals.size == reals.unsafe_fetch(reals.size - 1) - reals.unsafe_fetch(0) + 1 &&
                reals.unsafe_fetch(0) < rl <= reals.unsafe_fetch(reals.size - 1)
            # The line's rows are consecutive and both rows are among them.
            prefix = @_row_prefix + (wl[rl - 1]? || "").size
          end
        else
          bounds = buf_line_bounds(fake)
          @_row_line = bounds
          @_row_tabs = buf_range_includes_tab?(bounds[0], bounds[1])
        end
        unless prefix
          prefix = 0
          (reals || [rl]).each do |r|
            break if r >= rl
            prefix += (wl[r]? || "").size
          end
        end
        @_row_rl = rl
        @_row_fake = fake
        @_row_prefix = prefix
        @_row_wrap = wrap

        base, line_end = @_row_line
        size = buf_size
        {(base + row_unexpand_col(base, line_end, prefix)).clamp(0, size),
         (base + row_unexpand_col(base, line_end, prefix + line_display_width(rl))).clamp(0, size)}
      end

      # `#unexpand_col_in` for the line `#row_buffer_bounds` holds, with its
      # TAB scan already done.
      private def row_unexpand_col(base : Int32, line_end : Int32, exp_col : Int32) : Int32
        return Math.min(exp_col, line_end - base) unless @_row_tabs
        unexpand_col(buf_line_text_at(base, line_end), exp_col)
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
          # itself). An edit patches the lines it touched right here;
          # anything else leaves the display to the next frame's full push
          # (`#sync_display`). A change this view did not make is noted
          # (`#note_document_text_change`) and told of once it is finished,
          # as Qt's every view does.
          follow_document_change(e.kind, e.position, e.chars_removed, e.chars_added)
          patch_display e.kind, e.position, e.chars_removed, e.chars_added
          sync_line_number_width if @line_numbers
          update! if window?
          note_document_text_change e.kind, e.chars_removed, e.chars_added
        end
        wire_document_text_changed
      end

      # Patches the displayed lines for an edit, via
      # `Widget#replace_content_lines`: the lines the edit leaves from its
      # first block through the block its inserted text ends in replace the
      # lines it took — as many fewer as the block count grew. Needs a
      # display that is current and a document that was and stays non-empty
      # (an empty one shows the placeholder through the full push). Any
      # other change marks the display stale for the full push.
      private def patch_display(kind : TextDocument::ChangeKind, pos : Int32, removed : Int32, added : Int32) : Nil
        fresh = @_display_fresh
        @_display_fresh = false
        return unless fresh && kind.edit?
        doc = document
        size = doc.size
        return if size == 0 || size - added + removed == 0
        first = doc.block_at(pos).index
        last = added > 0 ? doc.block_at(pos + added).index : first
        blocks = doc.block_count
        # The display splits lines at a `\r` too, which the document keeps
        # inside a block: its lines are then not the blocks, and a block's
        # index names another line.
        return unless @wrapped_lines.fake.size == @_display_blocks
        old_count = last - first + 1 - (blocks - @_display_blocks)
        return if old_count < 1
        text = first == last ? doc.blocks[first].text : doc.plain_text(doc.block_position(first), doc.block_position(last) + doc.blocks[last].size)
        return unless replace_content_lines(first, old_count, Unicode.picture_controls(text))
        @_display_blocks = blocks
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
        @_row_fake = -1
        # Before the display syncs, so this frame's wrap width already holds
        # the gutter the current line count needs.
        sync_line_number_width if @line_numbers
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
          # An earlier patch's caret follow is this push's.
          @_display_patched = false
          @_display_blocks = document.block_count
          if v == @_display_value
            @follow_caret = false
            return
          end
          @_display_value = v
          set_content(v.empty? && !@placeholder_text.empty? ? @placeholder_text : Unicode.picture_controls(v))
        end
        # The caret follows a change of this view's own; one made elsewhere
        # moves the view only as `Widget#follow_tail?` does.
        _type_scroll if take_caret_follow
        _update_cursor
      end
    end
  end
end
