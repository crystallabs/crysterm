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

        # `ContentsChangeFinished` handler on the current document
        # (`#wire_document_text_changed`), detached with `@ev_contents_change`.
        @ev_contents_change_finished : ::EventHandler::Subscription?

        # Set once the view is destroyed (`#leave_document`): a document given
        # to it afterwards is not wired, which would subscribe the dead view
        # again.
        @document_left = false

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
        end

        def buf_delete(from : Int32, to : Int32) : Nil
          return if to <= from
          as_self_edit { document.remove(from, to - from) }
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
        # OSC-52 system clipboard can take) — the fragment's, which reads a
        # wrapped table row line by line.
        def buf_copy_to_clipboard(clipboard : Crysterm::Application::Clipboard, from : Int32, to : Int32, window : Crysterm::Window? = nil) : Nil
          fragment = document.copy_fragment(from, to)
          clipboard.copy(fragment, fragment.to_plain_text, window)
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

        # Undoes the last document edit step — whichever view or cursor made
        # it, the document's undo stack being shared — and puts the caret
        # where the change was undone (Qt `QWidgetTextControl::undo`, which
        # calls `QTextDocument::undo(&cursor)`): after text it put back,
        # where text it took out was, after a range whose format it changed.
        # Returns whether anything was undone.
        def undo : Bool
          replay { |cursor| document.undo(cursor) }
        end

        # Redoes the last undone document edit step; caret placement as in
        # `#undo`, at the end of the change redone. Returns whether anything
        # was redone.
        def redo : Bool
          replay { |cursor| document.redo(cursor) }
        end

        # Runs an undo or redo through a cursor at the caret, which the
        # document moves to the change replayed (or leaves, for a step with
        # no place, such as a table's cells), and puts the caret there, the
        # selection dropped.
        private def replay(& : TextCursor -> Bool) : Bool
          cursor = TextCursor.new(document, @cursor_pos)
          return false unless as_self_edit { yield cursor }
          @cursor_pos = cursor.position.clamp(0, buf_size)
          clear_selection
          @goal_col = nil
          true
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
        # hook, re-wires, requests a render, and emits `Event::DocumentChanged`,
        # then reports the caret's rewind (`CursorPositionChanged`,
        # `SelectionChanged`) at once, as Qt's `setDocument` does, rather than
        # at the next keystroke. Each widget's `document=` is a same-document
        # guard plus this call.
        protected def swap_document(doc : TextDocument) : Nil
          unwire_document
          @document = doc
          # The typing format belongs to the old document.
          @typing_format = nil
          @cursor_pos = 0
          clear_selection
          @goal_col = nil
          reset_document_caches
          wire_document unless @document_left
          update
          update! if window?
          emit Crysterm::Event::DocumentChanged, doc
          emit_caret_events
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
          @ev_contents_change_finished.try &.off
          @ev_contents_change_finished = nil
          @_document_text_changed = false
        end

        # Has the view tell of a change of its document that it did not make
        # once the change is finished (`Event::ContentsChangeFinished`,
        # `#emit_document_text_changed`); the includer's `#wire_document` calls
        # it beside subscribing its `ContentsChanged` handler, which notes the
        # change's steps (`#note_document_text_change`).
        private def wire_document_text_changed : Nil
          @ev_contents_change_finished = document.on(Crysterm::Event::ContentsChangeFinished) do
            emit_document_text_changed
          end
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

        # Render-time format overlays (Qt `QTextEdit::ExtraSelection`, which
        # `QPlainTextEdit` shares): each `Widget::TextEdit::ExtraSelection`
        # paints its cursor's selected range with its format merged over the
        # text's own, or — with no selection and `full_width` — the whole
        # display row(s) holding the cursor's position: the current-line
        # highlight idiom, re-set on every `Event::CursorPositionChanged` as
        # in Qt's code editor example. Held here, as Qt holds them in the
        # `QWidgetTextControl` both edits delegate to (so do `#text_cursor`
        # and `#text_cursor=`). `TextEdit` paints them in its own painter,
        # `PlainTextEdit` through `Widget#extra_selections_for_row`.
        getter extra_selections = [] of Widget::TextEdit::ExtraSelection

        def extra_selections=(list : Array(Widget::TextEdit::ExtraSelection))
          @extra_selections = list
          overlays_changed
          list
        end

        # Repaints for a change of the render-time overlays (the extra
        # selections, the current-line tint): they are not content, so no
        # document change announces them.
        private def overlays_changed : Nil
          update
          update! if window?
        end

        # Whether the display row(s) holding the caret are tinted
        # (`#current_line_format`): the current-line highlight of code
        # editors. Qt's code editor example builds it from a full-width
        # `ExtraSelection` re-set on every caret move; here it is a view
        # property, painted under the extra selections at render time, so
        # `#extra_selections` stays the app's own and nothing is re-set.
        getter? highlight_current_line : Bool = false

        def highlight_current_line=(value : Bool) : Bool
          return value if value == @highlight_current_line
          @highlight_current_line = value
          overlays_changed
          value
        end

        # The format of the caret's row while `#highlight_current_line?`;
        # `nil` (the default) for a tint derived from the widget's own
        # background — lighter on a dark one, darker on a light one, by
        # `CURRENT_LINE_LIFT` — so it reads under any stylesheet.
        getter current_line_format : TextCharFormat?

        def current_line_format=(fmt : TextCharFormat?) : TextCharFormat?
          @current_line_format = fmt
          overlays_changed
          fmt
        end

        # Lightness step the derived `#current_line_format` takes off the
        # widget's background.
        CURRENT_LINE_LIFT = 0.14

        # `#current_line_format`, or the derived tint.
        protected def current_line_format_in_effect : TextCharFormat
          @current_line_format || begin
            bg = style.bg
            surface = (bg.nil? || bg < 0) ? Colors.default_bg_rgb : bg
            tint = if Colors.luminance(surface) < 0.5
                     Colors.lighten(surface, CURRENT_LINE_LIFT)
                   else
                     Colors.darken(surface, CURRENT_LINE_LIFT)
                   end
            TextCharFormat.new(bg: tint)
          end
        end

        # Extra selections overlapping the row `[row_start, row_end]`:
        # `{ranges of viewport columns + format}` for ranged ones, and the
        # merged format of full-width ones touching the row (painted across the
        # whole region width) — over the current-line tint when the caret is
        # on the row and `#highlight_current_line?`.
        protected def row_extra_selections(row_start : Int32, row_end : Int32, offset : Int32 = 0) : Tuple(Array(Tuple(Range(Int32, Int32), TextCharFormat))?, TextCharFormat?)
          return {nil, nil} if @extra_selections.empty? && !@highlight_current_line
          ranged = nil
          full_fmt = nil
          if @highlight_current_line && position_on_row?(@cursor_pos, row_start, row_end)
            full_fmt = current_line_format_in_effect
          end
          @extra_selections.each do |xs|
            c = xs.cursor
            if c.selection?
              s = Math.max(c.selection_start, row_start)
              e = Math.min(c.selection_end, row_end)
              next if s >= e
              if xs.full_width
                full_fmt = full_fmt ? full_fmt.merge(xs.format) : xs.format
              else
                cols = (offset + rendered_column(row_start, s) - @child_base_x)...(offset + rendered_column(row_start, e) - @child_base_x)
                ranged ||= [] of Tuple(Range(Int32, Int32), TextCharFormat)
                ranged << {cols, xs.format}
              end
            elsif xs.full_width && position_on_row?(c.position, row_start, row_end)
              full_fmt = full_fmt ? full_fmt.merge(xs.format) : xs.format
            end
          end
          {ranged, full_fmt}
        end

        # Whether buffer position *pos* is drawn on the row `[row_start,
        # row_end]`: inside it, or at its end when that end is a line end (or
        # the document's) — as Qt's `lineForTextPosition` reads it. At a soft
        # wrap the end position is the next row's start and belongs to that
        # row, so a caret there tints one row, not two.
        private def position_on_row?(pos : Int32, row_start : Int32, row_end : Int32) : Bool
          return false if pos < row_start || pos > row_end
          pos < row_end || pos >= buf_size || buf_char(pos) == '\n'
        end

        # A `TextCursor` materializing this view's caret and selection (Qt
        # `textCursor`). A *snapshot*: mutating it edits the document but does
        # not move the widget's caret — assign it back via `#text_cursor=`.
        def text_cursor : TextCursor
          c = TextCursor.new(document, @selection_anchor || @cursor_pos)
          c.set_position(@cursor_pos, :keep_anchor)
          c
        end

        # Adopts *c*'s position/anchor as the widget caret/selection (Qt
        # `setTextCursor`): the view scrolls to keep the caret on window
        # (`#ensure_cursor_visible`) and `Event::CursorPositionChanged` /
        # `Event::SelectionChanged` report the move, as for a keystroke — the
        # way another widget (a preview following an editor, a search box)
        # places this view's caret.
        def text_cursor=(c : TextCursor)
          @cursor_pos = c.position.clamp(0, buf_size)
          @selection_anchor = c.selection? ? c.anchor.clamp(0, buf_size) : nil
          @goal_col = nil
          ensure_cursor_visible
          emit_caret_events
          update
          update! if window?
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
            np = document.position_after_change(@cursor_pos, pos, removed, added)
            if a = @selection_anchor
              na = document.position_after_change(a, pos, removed, added)
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
        # explicit (possibly shared) *doc* — which wins over `content:` — with
        # the caret at its start, as Qt's `setDocument` puts it (and
        # `#document=` does), or else seeds a fresh document from *content*. Must run *before* `super`
        # (see `#setup_text_buffer`'s contract); pair with
        # `#finish_document_setup` after it.
        protected def adopt_document(doc : TextDocument?, content : String, max_length, read_only) : Nil
          if doc
            @document = doc
            @max_length = max_length
            @read_only = read_only
            @cursor_pos = 0
          else
            setup_text_buffer(content, max_length, read_only)
          end
        end

        # Post-`super` half of a document-backed widget's constructor: installs
        # the shared editing keys and then this view's document
        # `ContentsChanged` handler (`#wire_document`, defined by the includer),
        # and has the view leave its document when it is destroyed
        # (`#leave_document`).
        protected def finish_document_setup(input_on_focus, install_enter) : Nil
          setup_text_editing input_on_focus: input_on_focus, install_enter: install_enter
          wire_document
          on(Crysterm::Event::Destroy, once: true) { leave_document }
          @buf_content_delegated = true
        end

        # Lets go of the document as the view is destroyed, as a Qt view's
        # connections to its document die with it: the `ContentsChanged`
        # handler goes (`#unwire_document`), so a document outliving the view
        # — shared with another, or kept by the application — no longer calls
        # into a dead widget nor keeps it alive, and the extra selections
        # registered on the document are dropped.
        private def leave_document : Nil
          @document_left = true
          unwire_document
          @extra_selections = [] of Widget::TextEdit::ExtraSelection
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
