require "./buffer"

module Crysterm
  module Mixin
    module TextEditing
      # `TextDocument`-backed implementation of the `Buffer` protocol: flat
      # positions map 1:1 onto document positions (blocks joined by an implicit
      # `'\n'`, one position each), and mutations go through the document's
      # undoable editing API, so character formats survive edits and every
      # keystroke is recorded on the undo stack.
      #
      # Include alongside `Mixin::TextEditing`. The includer owns reacting to
      # document changes (layout invalidation, re-render) by listening to
      # `Event::ContentsChanged`, and defines `#wire_document` to install that
      # handler.
      module DocumentBuffer
        # The document this view edits. Lazy default so a standalone widget just
        # works; `#document=` swaps in a shared one (several views can edit the
        # same document, Qt semantics).
        getter document : TextDocument { TextDocument.new }

        # Tracker cursor registered on the document, kept at the end of this
        # view's last mutation. Because registered cursors are re-adjusted by
        # every edit — including undo/redo replays — its position after
        # `#undo`/`#redo` is where the replayed change landed, which is where
        # the caret should go (Qt behavior).
        getter edit_cursor : TextCursor { TextCursor.new(document) }

        # Char format applied to the next inserts (Qt's cursor "typing format").
        # `nil` inherits the format at the insertion point. Deviation from Qt:
        # persists across cursor movement until replaced or cleared.
        property typing_format : TextCharFormat?

        # Set while a mutation initiated *through this buffer* is inside the
        # document, so `#follow_document_change` can tell own edits (whose
        # caret the mixin moves itself) from edits by other actors on a
        # shared document (whose caret shift this view must mirror).
        @self_edit = false

        # `ContentsChanged` handler wrapper on the current document, so
        # `#unwire_document`/`#swap_document` can detach it. The includer's
        # `#wire_document` installs it.
        @ev_contents_change : ::EventHandler::Subscription?

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
          return if from >= size
          from = Math.max(from, 0)
          if ch == '\n'
            loc = document.block_at(from)
            bi = loc.index
            return if bi >= document.block_count - 1
            document.block_position(bi) + document.blocks[bi].size
          else
            # One block lookup for the whole scan (`each_char_forward`), not
            # one `char_at` binary search + codepoint index per position.
            i = from
            found = nil
            document.each_char_forward(from) do |c|
              if c == ch
                found = i
                false
              else
                i += 1
                true
              end
            end
            found
          end
        end

        def buf_rindex(ch : Char, from : Int32) : Int32?
          return if from < 0
          from = Math.min(from, buf_size - 1)
          return if from < 0
          if ch == '\n'
            loc = document.block_at(from)
            bi = loc.index
            off = loc.offset
            # `from` sitting exactly on a separator matches it (inclusive
            # semantics, like `String#rindex`).
            return from if off == document.blocks[bi].size && bi < document.block_count - 1
            bi > 0 ? document.block_position(bi) - 1 : nil
          else
            # `from` is inclusive, and `each_char_backward`'s start is
            # exclusive, so the scan begins at `from + 1` (<= document size,
            # since `from` was clamped to `buf_size - 1`).
            i = from
            found = nil
            document.each_char_backward(from + 1) do |c|
              if c == ch
                found = i
                false
              else
                i -= 1
                true
              end
            end
            found
          end
        end

        # Rich copy: the clipboard carries the selection as a formatted
        # `TextDocumentFragment` alongside its plain text (which is all the
        # OSC-52 system clipboard can take).
        def buf_copy_to_clipboard(clipboard : Crysterm::Application::Clipboard, from : Int32, to : Int32, window : Crysterm::Window? = nil) : Nil
          clipboard.copy(document.copy_fragment(from, to), document.plain_text(from, to), window)
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
          document.edit { yield }
        end

        # O(log) override of the mixin's flat prefix scan: the block index IS the
        # logical-line index and the column is measured line-locally (from the
        # block start to *c*), so no `0..c` document prefix is materialized.
        #
        # The tab-free line — overwhelmingly the common one, and the one every
        # keystroke re-measures — needs no prefix String at all: `expanded_width`
        # is a codepoint count, so with nothing to expand it IS the block-local
        # offset `block_at` already returned (true regardless of `full_unicode?`,
        # which this column space deliberately does not consult).
        private def cursor_line_col(c : Int32) : Tuple(Int32, Int32)
          loc = document.block_at(c)
          bi = loc.index
          off = loc.offset
          t = document.blocks[bi].text
          {bi, t.includes?('\t') ? expanded_width(t[0, off]) : off}
        end

        # Document-backed overrides of the mixin's two-phase word scans (which
        # classify one position at a time through `buf_char`, i.e. a `block_at`
        # binary search plus O(offset) codepoint indexing *per character*).
        # Same phase order — separator run first, then the non-separator run —
        # driven by one `TextDocument` block lookup for the whole scan.
        private def scan_word_left(&) : Int32
          p = @cursor_pos
          in_sep = true
          document.each_char_backward(p) do |c|
            sep = yield c
            in_sep = false unless sep
            if in_sep || !sep
              p -= 1
              true
            else
              false
            end
          end
          p
        end

        # :ditto: (forward; bounded by the document end, as `buf_size` bounds
        # the mixin's version).
        private def scan_word_right(&) : Int32
          p = @cursor_pos
          in_sep = true
          document.each_char_forward(p) do |c|
            sep = yield c
            in_sep = false unless sep
            if in_sep || !sep
              p += 1
              true
            else
              false
            end
          end
          p
        end

        # Word-run bounds around *pos* (double-click word select), scanned out
        # in both directions with the same primitives instead of a per-position
        # `buf_char`.
        private def word_bounds_at(pos : Int32) : Tuple(Int32, Int32)
          s = pos
          document.each_char_backward(pos) do |c|
            word_char?(c) ? (s -= 1; true) : false
          end
          e = pos
          document.each_char_forward(pos) do |c|
            word_char?(c) ? (e += 1; true) : false
          end
          {s, e}
        end

        # A logical line is exactly one block; check its (cached) text for a TAB
        # rather than letting the mixin's `buf_index` char-walk over-scan the
        # whole document (`'\t'` isn't a block separator, so it has no O(log)
        # path).
        private def buf_range_includes_tab?(from : Int32, to : Int32) : Bool
          return false if to <= from
          loc = document.block_at(from)
          bi = loc.index
          document.blocks[bi].text.includes?('\t')
        end

        # Fake (logical) lines are exactly the document's blocks.
        def buf_line_bounds(fake_line : Int32) : Tuple(Int32, Int32)
          k = fake_line.clamp(0, document.block_count - 1)
          bp = document.block_position(k)
          {bp, bp + document.blocks[k].size}
        end

        # A logical line IS a block, whose `text` the block already holds — so
        # the whole-line reads in the geometry (`line_display_width`,
        # `position_at`, the TAB arm of `unexpand_col_in`) borrow that cached
        # String instead of `String.build`ing a copy per row per frame.
        def buf_line_text(fake_line : Int32) : String
          document.blocks[fake_line.clamp(0, document.block_count - 1)].text
        end

        # :ditto: — *from* is a logical line start, i.e. a block position, so
        # the block it falls in is that whole line (see the protocol's contract
        # on this overload).
        def buf_line_text_at(from : Int32, to : Int32) : String
          document.blocks[document.block_at(from).index].text
        end

        def value : String
          document.to_plain_text
        end

        # External set: replaces the whole document content (plain text, not
        # undoable — Qt `setPlainText` semantics: the undo stack clears) and
        # parks the caret at the end. The document's `ContentsChanged` signal
        # drives the widget's relayout/render, so no display work happens here.
        def value=(value : String)
          as_self_edit { document.set_plain_text(value) }
          @cursor_pos = buf_size
          clear_selection
          @goal_col = nil
          emit_caret_events
        end

        # Once-per-frame redisplay (from `#paint`): just clamps the caret,
        # leaving the content (and the vertical goal column) untouched.
        def refresh_value : Nil
          @cursor_pos = @cursor_pos.clamp(0, buf_size)
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

        # Handles the undo/redo editing keys: `C-z` undo, `M-z` redo (`C-S-z` is
        # indistinguishable from `C-z` on most terminals; the emacs default `C-y`
        # stays yank). `Mixin::TextEditing` has no undo awareness, so the
        # including widget's `_listener` must call this first — before its own
        # handling — and return when it consumed the key. `TextChanged` is emitted
        # only when the buffer text actually changed.
        protected def handle_undo_redo_key(e : ::Crysterm::Event::KeyPress) : Bool
          if !read_only? && (k = e.key)
            if k == Tput::Key::CtrlZ || k == Tput::Key::AltZ
              e.accept
              # A non-kill action ends the consecutive-kill run (emacs semantics).
              kill_ring.interrupt if Crysterm::Config.input_readline_keys
              # Both snapshots exist *only* to decide whether to emit — the
              # repaint below is unconditional — so with nobody listening we
              # skip two full document serializations per undo/redo.
              want = text_change_observed?
              before = want ? buf_text : nil
              if k == Tput::Key::CtrlZ ? undo : redo
                ensure_cursor_visible
                ensure_cursor_visible_x
                if want && (after = buf_text) != before
                  # `TextChanged` only: undo/redo replay is not a user *edit*
                  # in Qt's `textEdited` sense.
                  emit Crysterm::Event::TextChanged, after
                end
                emit_caret_events
                update!
                _update_cursor
              end
              return true
            end
          end
          false
        end

        # Shared `document=` body (Qt `setDocument`): unwires the old document's
        # `ContentsChanged` handler, swaps in *doc*, resets the shared
        # caret/selection/typing state, runs the widget's `#reset_document_caches`
        # hook, re-wires, and requests a render. Each widget's `document=` is a
        # same-document guard plus this call.
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
          update
          update! if window?
        end

        # Replaces the edited document (Qt `setDocument`), e.g. to share one
        # document between several views. The caret rewinds to the start and
        # the widget's display caches drop (`#reset_document_caches`).
        def document=(doc : TextDocument)
          return if doc.same?(@document)
          swap_document(doc)
        end

        # Widget-specific display cache reset run by `#swap_document` between the
        # shared field resets and `#wire_document`. Empty by default.
        protected def reset_document_caches : Nil
        end

        private def unwire_document : Nil
          @ev_contents_change.try &.off
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
        # skipped: the mixin logic moves the caret itself.
        def follow_document_change(kind : TextDocument::ChangeKind, pos : Int32, removed : Int32, added : Int32) : Nil
          return if @self_edit
          case kind
          when .edit?
            return if removed == 0 && added == 0
            np = TextDocument.shift_position(@cursor_pos, pos, removed, added)
            if a = @selection_anchor
              na = TextDocument.shift_position(a, pos, removed, added)
              # A collapsed anchor is a landmine — drop it rather than leaving
              # it equal to the caret.
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

        # Pre-`super` half of a document-backed widget's constructor: adopts an
        # explicit (possibly shared) *doc* — which wins over `content:` — or
        # else seeds a fresh document from *content*. Must run *before* `super`
        # (see `#setup_text_buffer`'s contract); pair with
        # `#finish_document_setup` after it.
        protected def adopt_document(doc : TextDocument?, content : String, max_length, read_only) : Nil
          if doc
            @document = doc
            @max_length = max_length
            @read_only = read_only
            @cursor_pos = doc.size
          else
            setup_text_buffer(content, max_length, read_only)
          end
        end

        # Post-`super` half of a document-backed widget's constructor: installs
        # the shared editing keys and then this view's document
        # `ContentsChanged` handler (`#wire_document`, defined by the includer).
        protected def finish_document_setup(input_on_focus, install_enter) : Nil
          setup_text_editing input_on_focus: input_on_focus, install_enter: install_enter
          wire_document
          @buf_content_delegated = true
        end

        # Once true, a document-backed widget MAY re-point the widget-level
        # `content` accessors at the document (see `TextEdit#set_content`).
        # False during construction: the base `Widget#initialize` seeds
        # `@content` before the document plumbing is wired (and the
        # constructor separately adopts `content:` into the document), so the
        # seeding call must keep base behavior.
        #
        # The re-pointing itself deliberately lives on `TextEdit`, NOT here:
        # `PlainTextEdit`'s paint pipeline *uses* the base widget content as
        # its display surface (`sync_display` pushes the buffer text through
        # `set_content` on every document change), so for it the inherited
        # accessors are live plumbing, not the inert legacy surface they are
        # on `TextEdit`.
        @buf_content_delegated = false
      end
    end
  end
end
