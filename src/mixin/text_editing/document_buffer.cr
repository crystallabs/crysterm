require "./buffer"

module Crysterm
  module Mixin
    module TextEditing
      # `TextDocument`-backed implementation of the `Buffer` protocol
      # (TEXTEDIT.md §5): flat positions map 1:1 onto document positions
      # (blocks joined by an implicit `'\n'`, one position each — exactly the
      # `TextDocument` coordinate system), and mutations go through the
      # document's undoable editing API, so character formats survive edits
      # and every keystroke is recorded on the undo stack.
      #
      # `Widget::TextEdit` includes this alongside `Mixin::TextEditing`. The
      # includer owns reacting to document changes (layout invalidation,
      # re-render) by listening to `Event::ContentsChanged` — see
      # `TextEdit#document=`.
      module DocumentBuffer
        # The document this view edits. Lazy default so a standalone widget
        # just works; `Widget::TextEdit#document=` swaps in a shared one
        # (several views can edit the same document, Qt semantics).
        getter document : TextDocument { TextDocument.new }

        # Tracker cursor registered on the document, kept at the end of this
        # view's last mutation. Because registered cursors are re-adjusted by
        # every edit — including undo/redo replays — its position after
        # `#undo`/`#redo` is where the replayed change landed, which is where
        # the caret should go (Qt behavior).
        getter edit_cursor : TextCursor { TextCursor.new(document) }

        # Char format applied to the next inserts (Qt's cursor "typing
        # format"), set by `TextEdit#merge_current_char_format` with no
        # selection. `nil` inherits the format at the insertion point.
        # Deviation from Qt: persists across cursor movement until replaced
        # or cleared (the shared `Mixin::TextEditing` motion code has no
        # movement hook to clear it from).
        property typing_format : TextCharFormat?

        # Set while a mutation initiated *through this buffer* is inside the
        # document, so `#follow_document_change` can tell own edits (whose
        # caret the mixin moves itself) from edits by other actors on a
        # shared document (whose caret shift this view must mirror).
        @self_edit = false

        # `ContentsChanged` handler wrapper on the current document, so
        # `#unwire_document`/`#swap_document` can detach it. The includer's
        # `#wire_document` (which differs per widget — follow vs relayout)
        # installs it.
        @ev_contents_change : Crysterm::Event::ContentsChanged::Wrapper?

        def buf_text : String
          document.to_plain_text
        end

        def buf_size : Int32
          document.size
        end

        def buf_char(i : Int32) : Char
          document.char_at(i) || raise IndexError.new("buf_char: position #{i} out of bounds")
        end

        def buf_slice(from : Int32, to : Int32) : String
          document.plain_text(from, to)
        end

        def buf_insert(pos : Int32, str : String) : Nil
          return if str.empty?
          as_self_edit { document.insert_text(pos, str, @typing_format) }
          edit_cursor.set_position(pos + str.size)
        end

        def buf_delete(from : Int32, to : Int32) : Nil
          return if to <= from
          as_self_edit { document.remove(from, to - from) }
          edit_cursor.set_position(from)
        end

        # `'\n'` is the block separator, so both index scans resolve from the
        # document's block structure in O(log blocks) instead of a char walk;
        # other needles (none in the mixin today) fall back to a scan.
        def buf_index(ch : Char, from : Int32) : Int32?
          size = buf_size
          return nil if from >= size
          from = Math.max(from, 0)
          if ch == '\n'
            bi, _ = document.block_at(from)
            return nil if bi >= document.block_count - 1
            document.block_position(bi) + document.blocks[bi].size
          else
            (from...size).each do |i|
              return i if document.char_at(i) == ch
            end
            nil
          end
        end

        def buf_rindex(ch : Char, from : Int32) : Int32?
          return nil if from < 0
          from = Math.min(from, buf_size - 1)
          return nil if from < 0
          if ch == '\n'
            bi, off = document.block_at(from)
            # `from` sitting exactly on a separator matches it (inclusive
            # semantics, like `String#rindex`).
            return from if off == document.blocks[bi].size && bi < document.block_count - 1
            bi > 0 ? document.block_position(bi) - 1 : nil
          else
            from.downto(0) do |i|
              return i if document.char_at(i) == ch
            end
            nil
          end
        end

        # Rich copy: the clipboard carries the selection as a formatted
        # `TextDocumentFragment` alongside its plain text (which is all the
        # OSC-52 system clipboard can take) — TEXTEDIT.md Phase 3.
        def buf_copy_to_clipboard(clipboard : Crysterm::Application::Clipboard, from : Int32, to : Int32, window : Crysterm::Window? = nil) : Nil
          clipboard.set_rich(document.copy_fragment(from, to), document.plain_text(from, to), window)
        end

        # Rich paste: inserts the clipboard's fragment (formats intact,
        # `@typing_format` deliberately not applied) at the cursor, replacing
        # any selection as one undo step. Falls back to the caller's plain
        # path (returns false) when there is no rich payload — or when
        # `max_length` would require truncation, which the plain path knows
        # how to do and a fragment does not.
        def buf_paste_rich(clipboard : Crysterm::Application::Clipboard) : Bool
          frag = clipboard.fragment
          return false unless frag && frag.size > 0
          if ml = @max_length
            sel = selection_range.try { |r| r.end - r.begin } || 0
            return false if buf_size - sel + frag.size > ml
          end
          edit_replacing_selection do
            @goal_col = nil
            @cursor_pos += as_self_edit { document.insert_fragment(@cursor_pos, frag) }
            edit_cursor.set_position(@cursor_pos)
          end
          true
        end

        # Compound mixin actions (typing/pasting over a selection) group into
        # one undo step, Qt's edit-block semantics.
        def buf_edit_group(&)
          document.begin_edit_block
          begin
            yield
          ensure
            document.end_edit_block
          end
        end

        # O(log) override of the mixin's flat prefix scan: the block index IS the
        # logical-line index and the column is measured line-locally (from the
        # block start to *c*), so no `0..c` document prefix is materialized.
        private def cursor_line_col(c : Int32) : Tuple(Int32, Int32)
          bi, _ = document.block_at(c)
          base = document.block_position(bi)
          {bi, expanded_width(buf_slice(base, c))}
        end

        # A logical line is exactly one block; check its (cached) text for a TAB
        # rather than letting the mixin's `buf_index` char-walk over-scan the
        # whole document (`'\t'` isn't a block separator, so it has no O(log)
        # path).
        private def buf_range_includes_tab?(from : Int32, to : Int32) : Bool
          return false if to <= from
          bi, _ = document.block_at(from)
          document.blocks[bi].text.includes?('\t')
        end

        # Fake (logical) lines are exactly the document's blocks.
        def buf_line_bounds(fake_line : Int32) : Tuple(Int32, Int32)
          k = fake_line.clamp(0, document.block_count - 1)
          bp = document.block_position(k)
          {bp, bp + document.blocks[k].size}
        end

        def value : String
          document.to_plain_text
        end

        # External set replaces the whole document content (plain text, not
        # undoable — Qt `setPlainText` semantics: the undo stack clears) and
        # parks the caret at the end; `nil` is a redisplay that just clamps
        # the caret. The document's `ContentsChanged` signal drives the
        # widget's relayout/render, so no display work happens here.
        def value=(value = nil)
          if value
            as_self_edit { document.set_plain_text(value) }
            @cursor_pos = buf_size
            clear_selection
            @goal_col = nil
          else
            @cursor_pos = @cursor_pos.clamp(0, buf_size)
          end
        end

        # Undoes the last document edit step. The caret follows the tracker
        # cursor, which the replay just re-adjusted to the change site.
        # Returns whether anything was undone.
        def undo : Bool
          return false unless as_self_edit { document.undo }
          caret_to_tracker
          true
        end

        # Redoes the last undone document edit step; caret placement as in
        # `#undo`. Returns whether anything was redone.
        def redo : Bool
          return false unless as_self_edit { document.redo }
          caret_to_tracker
          true
        end

        private def caret_to_tracker : Nil
          @cursor_pos = edit_cursor.position.clamp(0, buf_size)
          clear_selection
          @goal_col = nil
        end

        # Handles the undo/redo editing keys shared by `Widget::PlainTextEdit`
        # and `Widget::TextEdit`: `C-z` undo, `M-z` redo (`C-S-z` is
        # indistinguishable from `C-z` on most terminals; the emacs default
        # `C-y` stays yank). The shared `Mixin::TextEditing` has no undo
        # awareness — it lives here — so each widget's `_listener` calls this
        # first (before its widget-specific handling) and returns when it
        # consumed the key. `TextChanged` is emitted only when the buffer text
        # actually changed (before/after diff).
        protected def handle_undo_redo_key(e) : Bool
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
                emit Crysterm::Event::TextChanged, after if after != before
                request_render
                _update_cursor
              end
              return true
            end
          end
          false
        end

        # Shared `document=` body (Qt `setDocument`): unwires the old
        # document's `ContentsChanged` handler, swaps in *doc*, resets the
        # shared caret/selection/typing state, runs the widget's
        # `#reset_document_caches` hook for its own display caches (in the same
        # position the per-widget resets occupied), re-wires, and requests a
        # render. Each widget's `document=` shrinks to a same-document guard
        # plus this call. (`#wire_document` genuinely differs per widget —
        # follow vs relayout — so it stays there.)
        protected def swap_document(doc : TextDocument) : Nil
          unwire_document
          @document = doc
          # The tracker cursor and typing format belong to the old document.
          @edit_cursor = nil
          @typing_format = nil
          @cursor_pos = 0
          clear_selection
          @goal_col = nil
          reset_document_caches
          wire_document
          mark_dirty
          request_render if window?
        end

        # Widget-specific display cache reset run by `#swap_document` between
        # the shared field resets and `#wire_document`. Empty by default;
        # `Widget::PlainTextEdit` clears its `@_display_value`, `Widget::TextEdit`
        # drops its block-layout cache.
        protected def reset_document_caches : Nil
        end

        private def unwire_document : Nil
          @ev_contents_change.try do |w|
            @document.try &.off(Crysterm::Event::ContentsChanged, w)
          end
          @ev_contents_change = nil
        end

        # Marks the document mutations made inside the block as this view's
        # own, so `#follow_document_change` leaves the caret to the caller.
        private def as_self_edit(&)
          @self_edit = true
          begin
            yield
          ensure
            @self_edit = false
          end
        end

        # Mirrors a document change made by another actor (a second view
        # sharing the document, a `TextCursor`, direct `TextDocument` calls)
        # onto this view's caret/selection — the same adjustment the document
        # applies to registered cursors, keyed by the change's
        # `TextDocument::ChangeKind`. The including widget calls this from its
        # `Event::ContentsChanged` handler. Own edits (`#as_self_edit`) are
        # skipped: the shared mixin logic moves the caret itself, exactly as
        # it does over a flat buffer.
        def follow_document_change(kind : TextDocument::ChangeKind, pos : Int32, removed : Int32, added : Int32) : Nil
          return if @self_edit
          case kind
          when .edit?
            return if removed == 0 && added == 0
            np = TextDocument.shift_position(@cursor_pos, pos, removed, added)
            if a = @selection_anchor
              na = TextDocument.shift_position(a, pos, removed, added)
              # A collapsed anchor is a landmine (see the mixin's mouse
              # handler) — drop it rather than leaving it equal to the caret.
              @selection_anchor = na == np ? nil : na
            end
            if np != @cursor_pos
              @cursor_pos = np
              @goal_col = nil
            end
          when .replace?
            # Whole-content swap: rewind like registered cursors do (an own
            # `value=`/interchange set re-places the caret right after this).
            @cursor_pos = 0
            clear_selection
            @goal_col = nil
          else
            # Format-only: positions are unaffected.
          end
        end

        # Seeds the document from the constructor args. Call from
        # `initialize` *before* `super` (`FlatBuffer#setup_text_buffer`
        # contract).
        private def setup_text_buffer(content : String, max_length, read_only) : Nil
          @max_length = max_length
          @read_only = read_only
          document.set_plain_text(content) unless content.empty?
          @cursor_pos = buf_size
        end
      end
    end
  end
end
