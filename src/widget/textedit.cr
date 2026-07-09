require "./abstract_scroll_area"
require "../mixin/interactive"
require "../mixin/text_editing"

module Crysterm
  class Widget
    # Rich text editor over a `TextDocument`, modeled after Qt's `QTextEdit`
    # (TEXTEDIT.md Phase 2).
    #
    # Derives `AbstractScrollArea` (Qt: `QTextEdit < QAbstractScrollArea`) and
    # shares all navigation/selection/kill/mouse behavior with `LineEdit`/
    # `PlainTextEdit` through `Mixin::TextEditing`; the difference is the
    # buffer adapter — `Mixin::TextEditing::DocumentBuffer` maps the mixin's
    # flat positions onto the document and routes mutations through its
    # undoable editing API, so character formats survive edits and `C-z`/`M-z`
    # undo/redo work.
    #
    # Layout is a per-block wrap cache: each `TextBlock` wraps independently
    # into display rows (reusing `Widget#_wrap_content`), invalidated by the
    # document's `ContentsChange` for only the touched blocks, so edits stay
    # O(block), not O(document). The assembled rows fill `@_clines` — the same
    # structure the shared caret/selection geometry already reads — while
    # `@_pcontent` stays empty: the base `_render` paints only background/
    # borders/scroll bars, and `#paint_document` then writes the fragments
    # directly into the cell buffer with packed attributes. No tag or SGR
    # string is ever generated.
    #
    # The document is settable and shareable between views (Qt semantics):
    # `TextEdit.new(document: doc)` or `edit.document = doc`.
    class TextEdit < AbstractScrollArea
      include Mixin::Interactive
      include Mixin::TextEditing
      include Mixin::TextEditing::DocumentBuffer

      # A render-time format overlay (Qt `QTextEdit::ExtraSelection`): the
      # cursor's selected range is painted with `format` merged over the text's
      # own formats. With no selection and `full_width` set, the whole display
      # row(s) holding the cursor position are painted — the idiom for a
      # current-line highlight.
      record ExtraSelection,
        cursor : TextCursor,
        format : TextCharFormat,
        full_width : Bool = false

      getter extra_selections = [] of ExtraSelection

      def extra_selections=(list : Array(ExtraSelection))
        @extra_selections = list
        mark_dirty
        request_render if window?
        list
      end

      @scrollable = true
      # Same scroll model as `PlainTextEdit`: `@child_base` is the top visible
      # wrapped row, `@child_offset` stays 0, the `ScrollBar` drives the
      # viewport top and the caret (`@cursor_pos`) is tracked separately.
      @scrollbar_policy = ScrollBarPolicy::AsNeeded
      # Engages with `wrap_content: false` (long lines overflow to the right).
      @horizontal_scrollbar_policy = ScrollBarPolicy::AsNeeded

      # Per-block wrap cache, keyed by `TextBlock` identity: each entry is the
      # standalone `CLines` `#wrap_block` produced for that block under the
      # current `@layout_key`. `ContentsChange` deletes the touched blocks'
      # entries; `#rebuild_layout` rebuilds misses and drops entries whose
      # blocks left the document (via the swap-hash sweep).
      @block_layouts = {} of UInt64 => CLines
      @block_layouts_swap = {} of UInt64 => CLines

      # The layout inputs `@block_layouts` entries are valid for:
      # {colwidth, child_base_x, wrap_content?, content_margin_x}. Any change
      # invalidates every block (a width change re-wraps everything).
      @layout_key : Tuple(Int32, Int32, Bool, Int32)? = nil

      # Bumped on every document `ContentsChange`; `@layout_revision` is the
      # revision `@_clines` was assembled at, `@rendered_revision` the one the
      # caret-following scroll last ran for.
      @doc_revision = 0
      @layout_revision = -1
      @rendered_revision = -1

      @ev_contents_change : Crysterm::Event::ContentsChange::Wrapper?

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

      # Replaces the edited document (Qt `setDocument`), e.g. to share one
      # document between several views. The caret rewinds to the start and the
      # whole layout cache drops.
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
        @block_layouts.clear
        @layout_key = nil
        @doc_revision += 1
        wire_document
        mark_dirty
        request_render if window?
      end

      private def wire_document : Nil
        @ev_contents_change = document.on(Crysterm::Event::ContentsChange) do |e|
          on_contents_change(e.position, e.chars_removed, e.chars_added)
        end
      end

      private def unwire_document : Nil
        @ev_contents_change.try do |w|
          @document.try &.off(Crysterm::Event::ContentsChange, w)
        end
        @ev_contents_change = nil
      end

      # Document edit hook: drop the layout cache entries of the blocks now
      # overlapping the changed range (their wrapped rows are stale) and
      # request a repaint. Untouched blocks keep their rows — that's what
      # makes an edit O(block). Format-only changes report `removed == added`
      # and land in the same path: re-wrapping a block whose text didn't
      # change is cheap and keeps this hook simple (`set_plain_text` can also
      # report equal counts for genuinely different text).
      private def on_contents_change(pos : Int32, removed : Int32, added : Int32) : Nil
        @doc_revision += 1
        if removed > 0 || added > 0
          blocks = document.blocks
          b1 = document.block_at(pos)[0]
          b2 = document.block_at(pos + added)[0]
          (b1..b2).each do |i|
            blocks[i]?.try { |b| @block_layouts.delete(b.object_id) }
          end
        end
        mark_dirty
        request_render if window?
      end

      # === Layout ===

      # Replaces the base content pipeline: instead of parsing `@content`,
      # assemble `@_clines` from the per-block wrap cache. Returns whether a
      # relayout happened (base contract).
      def process_content(no_tags = false, awidth_hint : Int32? = nil)
        return false unless window?
        colwidth = (awidth_hint || awidth) - iwidth
        key = layout_cache_key(colwidth)
        if key == @layout_key && @layout_revision == @doc_revision && !@_clines.empty?
          # Steady frame. Keep the cached base attr fresh (a style change
          # recolors the background) — mirrors the base `process_content`.
          da = sattr(style)
          @_parse_attr_default = da if da != @_parse_attr_default
          return false
        end
        rebuild_layout(colwidth, key)
        # AsNeeded-bar convergence (see base `process_content`): the margin
        # the wrap consumed depends on the row count it produced. If the
        # produced rows flipped the bar's presence, re-wrap once — monotonic,
        # so two passes always suffice.
        key2 = layout_cache_key(colwidth)
        rebuild_layout(colwidth, key2) if key2 != key
        true
      end

      private def layout_cache_key(colwidth : Int32) : Tuple(Int32, Int32, Bool, Int32)
        {colwidth, @child_base_x, wrap_content?, content_margin_x}
      end

      # Assembles `@_clines` (rows + fake/real maps) from per-block layouts,
      # wrapping only blocks without a cache entry. The swap hash keeps only
      # blocks still in the document, so removed blocks' entries are swept.
      private def rebuild_layout(colwidth : Int32, key : Tuple(Int32, Int32, Bool, Int32)) : Nil
        @block_layouts.clear if key != @layout_key
        @layout_key = key
        @layout_revision = @doc_revision

        cl = @_clines
        cl.reset
        fake = cl.fake
        fake.clear
        full_width = 0
        max_width = 0

        fresh = @block_layouts_swap
        fresh.clear
        document.blocks.each_with_index do |blk, bi|
          bl = @block_layouts[blk.object_id]? || wrap_block(blk, colwidth)
          fresh[blk.object_id] = bl
          row_ids = cl.take_ftor_row
          bl.lines.each do |row|
            row_ids << cl.size
            cl.rtof << bi
            cl.push row
          end
          cl.ftor << row_ids
          fake << blk.text
          full_width = Math.max(full_width, bl.full_width)
          max_width = Math.max(max_width, bl.max_width)
        end
        @block_layouts, @block_layouts_swap = fresh, @block_layouts

        cl.fake = fake
        cl.width = colwidth
        cl.base_x = @child_base_x
        cl.margin = key[3]
        cl.full_width = full_width
        cl.max_width = max_width
        cl.real = cl
        cl.attr = nil
        # Keep the printable content empty: the base `_render` then paints
        # only the background fill (plus borders/bars/selection-on-fill), and
        # `#paint_document` draws the actual text over it.
        @_pcontent = ""
        # The base attr cache normally refreshes in base `process_content`.
        @_parse_attr_default = sattr(style)
      end

      # One block's display rows under the current layout inputs, via the
      # same wrap engine (`_wrap_content`) the base pipeline uses — identical
      # cut points, wide-char handling and `content_margin_x` reservation,
      # and the non-wrap `_hslice` viewport window. TABs are pre-expanded
      # exactly like `clean_content_chars` does, matching the tab-expanded
      # column units all the shared caret math runs in.
      private def wrap_block(blk : TextBlock, colwidth : Int32) : CLines
        text = blk.text
        text = text.gsub('\t', style.tab_char * style.tab_size) if text.includes?('\t')
        _wrap_content(text, colwidth)
      end

      # === Render ===

      def render
        # Relayout before following the caret: `ensure_cursor_visible` maps
        # the caret through `@_clines`, which a document edit just staled.
        process_content
        if @rendered_revision != @doc_revision
          @rendered_revision = @doc_revision
          # A shrinking document may leave the viewport past the end.
          clamp_child_base_to_content
          # Follow the caret after an edit (not on every frame — a wheel/bar
          # scroll away from the caret must stick).
          _type_scroll
        end
        ret = _render
        paint_document(ret) if ret
        ret
      end

      # Writes the visible document rows straight into the window's cell
      # buffer: per row, walk the text with a format-run pointer and emit
      # `{char, packed attr}` per cell — wide glyphs claim a continuation
      # cell, exactly like the base content loop. Overlays per cell, in
      # order: block background → char format → extra selections → mouse/key
      # selection highlight.
      # ameba:disable Metrics/CyclomaticComplexity
      private def paint_document(coords) : Nil
        scr = window
        lines_buf = scr.lines
        fu = scr.full_unicode?

        xi = coords.xi
        xl = coords.xl
        yi = coords.yi
        yl = coords.yl
        style.border.try { |b| xi, xl, yi, yl = b.adjust xi, xl, yi, yl }
        xi, xl, yi, yl = style.padding.adjust xi, xl, yi, yl
        yl -= hscrollbar_rows
        region_w = xl - xi
        return if region_w <= 0 || yl <= yi

        base_attr = @_parse_attr_default || sattr(style)
        # One raw TAB paints as this whole string (`tab_char` may be several
        # codepoints) — the same expansion the layout/caret math uses.
        tab_expansion = style.tab_char * style.tab_size
        bch = style.fill_char

        last_bi = -1
        runs = [] of Tuple(Int32, Int32, TextCharFormat)

        (yi...yl).each do |y|
          next if y < 0
          break if y >= scr.aheight
          line = lines_buf[y]? || next

          rl = coords.base + (y - yi)
          next if rl < 0 || rl >= @_clines.size
          bi = @_clines.rtof[rl]? || next
          blk = document.blocks[bi]? || next

          if bi != last_bi
            last_bi = bi
            runs = blk.format_runs(0, blk.size)
          end
          bfmt = blk.block_format
          block_bg = bfmt.bg
          heading = bfmt.heading?

          bp = document.block_position(bi)
          row_start = pos_from_rowcol(rl, 0)
          row_end = pos_from_rowcol(rl, line_display_width(rl))
          next if row_end < row_start

          sel_cols = selection_columns_for_row(rl)
          row_xsels, full_fmt = row_extra_selections(row_start, row_end)

          raw = blk.text
          ls = row_start - bp
          le = row_end - bp
          row_text = (ls == 0 && le == raw.size) ? raw : raw[ls, le - ls]

          # Viewport column of the row text's first character: 0 when
          # wrapping; shifted left by the horizontal scroll when not (the
          # off-view prefix advances `col` without painting).
          col = -@child_base_x
          lp = ls # block-local codepoint offset (indexes `runs`)
          ri = 0  # current format run
          run_attr = base_attr
          run_hi = -1 # `lp` bound the cached `run_attr` is valid below

          each_glyph(row_text, fu) do |ch, cluster, cps|
            break if col >= region_w

            if lp >= run_hi
              while ri < runs.size && lp >= runs[ri][1]
                ri += 1
              end
              if ri < runs.size && lp >= runs[ri][0]
                run_hi = runs[ri][1]
                run_attr = pack_char_attr(runs[ri][2], base_attr, block_bg, heading)
              else
                run_hi = Int32::MAX
                run_attr = pack_char_attr(nil, base_attr, block_bg, heading)
              end
            end

            if ch == '\t'
              tab_expansion.each_char do |tc|
                break if col >= region_w
                if col >= 0 && (cell = line[xi + col]?)
                  cell.set_if_changed(overlay_attr(run_attr, col, sel_cols, row_xsels, full_fmt), tc)
                end
                col += 1
              end
              lp += cps
              next
            end

            w = 1
            if fu
              w = cluster ? ::Crysterm::Unicode.width(cluster) : ::Crysterm::Unicode.width(ch)
              # A zero-width cluster (lone combining mark) still takes one
              # step, matching `column_index`'s caret math.
              w = 1 if w <= 0
            end

            if col + w <= 0
              # Entirely left of the viewport (horizontally scrolled).
              col += w
              lp += cps
              next
            end

            x = xi + col
            pattr = overlay_attr(run_attr, col, sel_cols, row_xsels, full_fmt)
            painted_lead = false
            if col >= 0 && (cell = line[x]?)
              if w == 2 && (col + 1 >= region_w || line[x + 1]?.nil?)
                # Half a wide glyph can't render at the right edge — blank
                # it, preserving the "width-2 cell is always followed by its
                # continuation" invariant (same safeguard as `_render`).
                cell.set_if_changed(pattr, ' ')
                w = 1
              elsif cluster
                if cell.attr != pattr || !cell.grapheme_eq?(cluster)
                  cell.attr = pattr
                  cell.grapheme = cluster
                  line.mark_dirty x
                end
              else
                cell.set_if_changed(pattr, ch)
              end
              painted_lead = true
            end

            if w == 2
              ncol = col + 1
              if ncol >= 0 && ncol < region_w && (nxt = line[x + 1]?)
                nattr = overlay_attr(run_attr, ncol, sel_cols, row_xsels, full_fmt)
                if painted_lead
                  nxt.attr = nattr
                  nxt.continuation!
                  line.mark_dirty(x + 1)
                else
                  # Lead fell left of the viewport: a continuation with no
                  # lead would desync the row — paint a plain blank instead.
                  nxt.set_if_changed(nattr, ' ')
                end
              end
            end

            col += w
            lp += cps
          end

          # Trailing cells past the text: normally the base fill already
          # painted them, but a block background or a full-width extra
          # selection (current-line highlight) must extend to the region edge.
          if block_bg || full_fmt
            trail = pack_char_attr(nil, base_attr, block_bg, heading)
            c2 = Math.max(col, 0)
            while c2 < region_w
              if cell = line[xi + c2]?
                cell.set_if_changed(overlay_attr(trail, c2, sel_cols, row_xsels, full_fmt), bch)
              end
              c2 += 1
            end
          end
        end
      end

      # Yields the row's paint units: `{lead char, cluster string or nil,
      # codepoints consumed}`. Grapheme clusters under `full_unicode?` (a
      # cluster paints as one cell + continuation), single codepoints
      # otherwise (legacy: one codepoint per cell, width 1 — matching
      # `str_width`'s legacy accounting the layout ran with).
      private def each_glyph(text : String, fu : Bool, & : (Char, String?, Int32) ->) : Nil
        if fu
          text.each_grapheme do |g|
            s = g.to_s
            yield s[0], (s.size > 1 ? s : nil), s.size
          end
        else
          text.each_char do |c|
            yield c, nil, 1
          end
        end
      end

      # Extra selections overlapping the row `[row_start, row_end]`:
      # `{ranges of viewport columns + format}` for ranged ones, and the
      # merged format of full-width ones touching the row (painted across the
      # whole region width).
      private def row_extra_selections(row_start : Int32, row_end : Int32) : Tuple(Array(Tuple(Range(Int32, Int32), TextCharFormat))?, TextCharFormat?)
        return {nil, nil} if @extra_selections.empty?
        ranged = nil
        full_fmt = nil
        @extra_selections.each do |xs|
          c = xs.cursor
          if c.has_selection?
            s = Math.max(c.selection_start, row_start)
            e = Math.min(c.selection_end, row_end)
            next if s >= e
            if xs.full_width
              full_fmt = full_fmt ? full_fmt.merge(xs.format) : xs.format
            else
              cols = (rendered_column(row_start, s) - @child_base_x)...(rendered_column(row_start, e) - @child_base_x)
              ranged ||= [] of Tuple(Range(Int32, Int32), TextCharFormat)
              ranged << {cols, xs.format}
            end
          elsif xs.full_width && c.position >= row_start && c.position <= row_end
            full_fmt = full_fmt ? full_fmt.merge(xs.format) : xs.format
          end
        end
        {ranged, full_fmt}
      end

      # The packed attr of one char: widget base attr + block background/
      # heading + the char format's SGR set. `dim` has no packed flag in the
      # cell model and is not rendered; anchors render underlined (their
      # click/OSC 8 behavior is `TextBrowser`/Phase 3+ territory).
      private def pack_char_attr(fmt : TextCharFormat?, base_attr : Int64, block_bg : Int32?, heading : Bool) : Int64
        flags = Attr.flags(base_attr)
        fg = Attr.fg(base_attr)
        bg = (bbg = block_bg) ? Attr.pack_color(bbg) : Attr.bg(base_attr)
        flags |= Attr::BOLD if heading
        if fmt
          flags |= Attr::BOLD if fmt.bold?
          flags |= Attr::ITALIC if fmt.italic?
          flags |= Attr::UNDERLINE if fmt.underline? || fmt.anchor?
          flags |= Attr::STRIKE if fmt.strike?
          flags |= Attr::REVERSE if fmt.inverse?
          flags |= Attr::BLINK if fmt.blink?
          if c = fmt.fg
            fg = Attr.pack_color(c)
          end
          if c = fmt.bg
            bg = Attr.pack_color(c)
          end
        end
        Attr.pack(flags, fg, bg)
      end

      # *attr* with this cell's overlays applied: extra selections (format
      # patches, mask-aware), then the mouse/keyboard selection highlight
      # (reverse video, same as the base render's `highlighted_attr`).
      private def overlay_attr(attr : Int64, col : Int32, sel_cols : Range(Int32, Int32)?, row_xsels : Array(Tuple(Range(Int32, Int32), TextCharFormat))?, full_fmt : TextCharFormat?) : Int64
        if f = full_fmt
          attr = merge_format_attr(attr, f)
        end
        row_xsels.try &.each do |(cols, f)|
          attr = merge_format_attr(attr, f) if cols.includes?(col)
        end
        highlighted_attr(attr, sel_cols, col)
      end

      # Applies a `TextCharFormat` as a patch over a packed attr (Qt merge
      # semantics: only attributes the format's mask specifies change; colors
      # apply when set).
      private def merge_format_attr(attr : Int64, fmt : TextCharFormat) : Int64
        flags = Attr.flags(attr)
        mask = fmt.attr_mask
        {% for a, flag in {bold: "BOLD", italic: "ITALIC", underline: "UNDERLINE", strike: "STRIKE", inverse: "REVERSE", blink: "BLINK"} %}
          if mask.{{a.id}}?
            if fmt.{{a.id}}?
              flags |= Attr::{{flag.id}}
            else
              flags &= ~Attr::{{flag.id}}.to_i64
            end
          end
        {% end %}
        fg = (c = fmt.fg) ? Attr.pack_color(c) : Attr.fg(attr)
        bg = (c = fmt.bg) ? Attr.pack_color(c) : Attr.bg(attr)
        Attr.pack(flags, fg, bg)
      end

      # === Editing keys ===

      # Adds undo/redo on top of the shared editing keys: `C-z` undo, `M-z`
      # redo (`C-S-z` is indistinguishable from `C-z` on most terminals, per
      # TEXTEDIT.md the emacs default `C-y` stays yank).
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

      # === Cursor / format API (Qt counterparts) ===

      # A `TextCursor` materializing this view's caret and selection (Qt
      # `textCursor`). A *snapshot*: mutating it edits the document but does
      # not move the widget's caret — assign it back via `#text_cursor=`.
      def text_cursor : TextCursor
        c = TextCursor.new(document, @selection_anchor || @cursor_pos)
        c.set_position(@cursor_pos, :keep_anchor)
        c
      end

      # Adopts *c*'s position/anchor as the widget caret/selection (Qt
      # `setTextCursor`).
      def text_cursor=(c : TextCursor)
        @cursor_pos = c.position.clamp(0, buf_size)
        @selection_anchor = c.has_selection? ? c.anchor.clamp(0, buf_size) : nil
        @goal_col = nil
        mark_dirty
        request_render if window?
      end

      # Format typing at the caret would get: the pending typing format, else
      # the preceding character's (Qt `currentCharFormat`).
      def current_char_format : TextCharFormat
        typing_format || document.char_format_at(@cursor_pos)
      end

      # Merges *fmt* into the selection's char formats (undoable), or into
      # the typing format when nothing is selected (Qt `mergeCurrentCharFormat`).
      def merge_current_char_format(fmt : TextCharFormat) : Nil
        if r = selection_range
          document.apply_char_format(r.begin, r.end, fmt, merge: true)
          edit_cursor.set_position(r.end)
        else
          self.typing_format = current_char_format.merge(fmt)
        end
      end

      # Replaces the selection's char format (undoable), or the typing format
      # when nothing is selected (Qt `setCurrentCharFormat`).
      def set_current_char_format(fmt : TextCharFormat) : Nil
        if r = selection_range
          document.apply_char_format(r.begin, r.end, fmt)
          edit_cursor.set_position(r.end)
        else
          self.typing_format = fmt
        end
      end
    end
  end
end
