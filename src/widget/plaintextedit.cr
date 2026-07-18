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
    # (`@_pcontent`), not `TextEdit`'s document paint path; `#value=` bridges the
    # document text back into `set_content`. The document is settable/shareable
    # between views, exactly like `TextEdit`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![PlainTextEdit screenshot](../../tests/widget/plaintextedit/plaintextedit.5s.apng)
    # <!-- /widget-examples:capture -->
    class PlainTextEdit < AbstractScrollArea
      include Mixin::Interactive
      include Mixin::TextEditing
      include Mixin::TextEditing::DocumentBuffer

      @scrollable = true
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
      @_display_value : String?

      def initialize(
        input_on_focus = false,
        max_length = nil,
        read_only = false,
        document : TextDocument? = nil,
        **input,
      )
        if document
          # An explicit (possibly shared) document wins over `content:`.
          @document = document
          @max_length = max_length
          @read_only = read_only
          @cursor_pos = document.size
        else
          setup_text_buffer(input["content"]? || "", max_length, read_only)
        end

        super **(input.merge({keys: true}))

        setup_text_editing input_on_focus: input_on_focus, install_enter: !!input["keys"]?

        wire_document
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

      # Replaces the edited document (Qt `setDocument`), e.g. to share one
      # document between several views. The caret rewinds to the start.
      def document=(doc : TextDocument)
        return if doc.same?(@document)
        swap_document(doc)
      end

      protected def reset_document_caches : Nil
        @_display_value = nil
      end

      private def wire_document : Nil
        @ev_contents_change = document.on(Crysterm::Event::ContentsChanged) do |e|
          # Mirror an edit made by another actor on a shared document onto this
          # view's caret (own edits are skipped — the mixin moves the caret
          # itself); the display re-syncs on the next render via `#value=`.
          follow_document_change(e.kind, e.position, e.chars_removed, e.chars_added)
          request_render if window?
        end
      end

      # Adds undo/redo on top of the shared editing keys.
      def _listener(e)
        return if handle_undo_redo_key(e)
        super
      end

      # External set: delegates to `DocumentBuffer#value=`, then pushes the
      # document's plain text into `set_content` (this widget renders through the
      # base `@_pcontent` pipeline rather than the `ContentsChanged` paint).
      def value=(value : String)
        super
        sync_display
      end

      # Once-per-frame redisplay (from `#render`): clamps the caret via
      # `DocumentBuffer#refresh_value`, then re-syncs `set_content` if it changed.
      def refresh_value : Nil
        super
        sync_display
      end

      # Pushes the document's plain text into `set_content` whenever it changed.
      private def sync_display : Nil
        v = buf_text
        return if v == @_display_value
        @_display_value = v
        set_content v
        _type_scroll
        _update_cursor
      end
    end
  end
end
