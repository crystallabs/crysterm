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
          # itself). An edit patches the lines it touched right here;
          # anything else leaves the display to the next frame's full push
          # (`#sync_display`).
          follow_document_change(e.kind, e.position, e.chars_removed, e.chars_added)
          patch_display e.kind, e.position, e.chars_removed, e.chars_added
          sync_line_number_width if @line_numbers
          update! if window?
        end
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
        old_count = last - first + 1 - (blocks - @_display_blocks)
        return if old_count < 1
        text = first == last ? doc.blocks[first].text : doc.plain_text(doc.block_position(first), doc.block_position(last) + doc.blocks[last].size)
        return unless replace_content_lines(first, old_count, text)
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
