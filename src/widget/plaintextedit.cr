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
    # Storage is a `TextDocument` via `Mixin::TextEditing::DocumentBuffer` — the
    # same architecture Qt uses (`QPlainTextEdit` drives a `QTextDocument` with a
    # plain layout), which is what gives editing undo/redo (`C-z` / `M-z`). The
    # document is plain (no rich formats are entered), so rendering still goes
    # through the base content pipeline (`@_pcontent`), not `TextEdit`'s document
    # paint path; `#value=` bridges the document text back into `set_content`.
    # The document is settable/shareable between views, exactly like `TextEdit`.
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
      # 0 (`#scroll` is a pure viewport scroll, `#ensure_cursor_visible` only
      # moves `@child_base`), so `get_scroll == child_base` and the attached
      # `ScrollBar` drives the viewport top, matching Qt (dragging the bar moves
      # the view, not the caret).
      @scrollbar_policy = ScrollBarPolicy::AsNeeded
      # Only engages with `wrap_content: false` (long lines run off the right
      # edge); `really_scrollable_x?` is false while wrapping.
      @horizontal_scrollbar_policy = ScrollBarPolicy::AsNeeded

      @ev_contents_change : Crysterm::Event::ContentsChange::Wrapper?
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

        # No need to register for keys here: `Widget#initialize` already does
        # that for widgets that ask for keys (`keys`/`input`).

        setup_text_editing input_on_focus: input_on_focus, install_enter: !!input["keys"]?

        wire_document
      end

      # Replaces the edited document (Qt `setDocument`), e.g. to share one
      # document between several views. The caret rewinds to the start.
      def document=(doc : TextDocument)
        return if doc.same?(@document)
        unwire_document
        @document = doc
        # The tracker cursor and typing format belong to the old document.
        @edit_cursor = nil
        @typing_format = nil
        @cursor_pos = 0
        clear_selection
        @goal_col = nil
        @_display_value = nil
        wire_document
        mark_dirty
        request_render if window?
      end

      private def wire_document : Nil
        @ev_contents_change = document.on(Crysterm::Event::ContentsChange) do |e|
          # Mirror an edit made by another actor on a shared document onto this
          # view's caret (own edits are skipped — the mixin moves the caret
          # itself); the display re-syncs on the next render via `#value=`.
          follow_document_change(e.kind, e.position, e.chars_removed, e.chars_added)
          request_render if window?
        end
      end

      private def unwire_document : Nil
        @ev_contents_change.try do |w|
          @document.try &.off(Crysterm::Event::ContentsChange, w)
        end
        @ev_contents_change = nil
      end

      # Adds undo/redo on top of the shared editing keys: `C-z` undo, `M-z`
      # redo (`C-S-z` is indistinguishable from `C-z` on most terminals; the
      # emacs default `C-y` stays yank). The shared `Mixin::TextEditing` has no
      # undo awareness — it lives on the `DocumentBuffer` — so, like
      # `Widget::TextEdit`, it is wired here before delegating to `super`.
      def _listener(e)
        if !read_only? && (k = e.key)
          if k == Tput::Key::CtrlZ || k == Tput::Key::AltZ
            e.accept
            # A non-kill action ends the consecutive-kill run (emacs
            # semantics) — same as the mixin's other early-return keys.
            kill_ring.interrupt if Crysterm::Config.input_readline_keys
            before = buf_text
            if k == Tput::Key::CtrlZ ? undo : redo
              ensure_cursor_visible
              ensure_cursor_visible_x
              after = buf_text
              emit Crysterm::Event::TextChange, after if after != before
              request_render
              _update_cursor
            end
            return
          end
        end
        super
      end

      # Re-adds the flat display half that `DocumentBuffer#value=` omits (it
      # relies on `ContentsChange` for a document paint, but `PlainTextEdit`
      # renders through the base `@_pcontent` content pipeline): push the
      # document's plain text into `set_content` whenever it changed. Mirrors
      # `FlatBuffer#value=`'s contract; the mixin's `#render` calls this with
      # `nil` every frame (a redisplay) and external sets pass the new text.
      def value=(value = nil)
        super
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
