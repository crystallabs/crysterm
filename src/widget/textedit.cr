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

      # Indent cells per list nesting level (`TextListFormat#indent - 1`
      # levels deep) — the terminal stand-in for Qt's per-level pixel indent.
      LIST_INDENT_CELLS = 2

      # Which marker patterns typed at the start of a block auto-convert it
      # into a list item (see `#auto_formatting`). Qt's `AutoFormattingFlag`
      # has only `AutoBulletList`; `NumberedList` (`"1. "`, `"1) "`) is an
      # extension in the same spirit.
      @[Flags]
      enum AutoFormatting
        # `- `, `* ` or `+ ` at block start starts a disc list.
        BulletList
        # `N. ` or `N) ` at block start starts a decimal list at N.
        NumberedList
      end

      # Enables auto-formatting while typing (Qt `QTextEdit::autoFormatting`;
      # default `None`, as in Qt): typing a list marker followed by a space
      # at the start of a plain block converts the block into a fresh list
      # item — the marker text is removed and re-appears as the rendered
      # list decoration. One undo step reverts the conversion (restoring the
      # typed marker text), a second removes the marker keystrokes.
      property auto_formatting : AutoFormatting = AutoFormatting::None

      # Per-display-row decoration metadata, parallel to `@_clines`
      # (TEXTEDIT.md Phase 4). `offset` is the column where the row's text
      # starts (frame insets + quote bars + indents + list marker + alignment
      # shift) — what the shared geometry reads through `#row_text_x_offset`;
      # `marker` is the list marker painted at the text's left edge (first
      # row of a list item only); a `margin` row is a blank row holding no
      # buffer positions (block margins and frame border rows). `fborder`
      # marks a frame border row: `{path index of the frame, top?}` — painted
      # as the frame's horizontal border with corners, the enclosing frames'
      # side bars running through it.
      private record RowMeta,
        offset : Int32,
        marker : String? = nil,
        margin : Bool = false,
        fborder : Tuple(Int32, Bool)? = nil

      # One block's cached wrap plus the decoration widths it was wrapped
      # for — list renumbering can change a marker's width (`"9. "` →
      # `"10. "`) without touching the block, so a mismatch forces a re-wrap;
      # `rdeco` is the right-side inset (frame borders/margins), which
      # shrinks the wrap width the same way.
      private record BlockLayout,
        deco : Int32,
        rdeco : Int32,
        lines : CLines

      # Colors for the structural decorations this widget paints itself
      # (list markers, quote bars, horizontal rules) — the same palette the
      # interchange importers use for text-level coloring, so a structurally
      # built document looks like an imported one.
      property theme : TextTheme = TextTheme.default

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
      # current `@layout_key`, wrapped at `colwidth - deco` (see
      # `BlockLayout`). `ContentsChange` deletes the touched blocks' entries;
      # `#rebuild_layout` rebuilds misses (and deco-width mismatches) and
      # drops entries whose blocks left the document (via the swap-hash
      # sweep).
      @block_layouts = {} of UInt64 => BlockLayout
      @block_layouts_swap = {} of UInt64 => BlockLayout

      # Decoration metadata per assembled display row (see `RowMeta`),
      # rebuilt alongside `@_clines` by `#rebuild_layout`.
      @row_meta = [] of RowMeta

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
        swap_document(doc)
      end

      protected def reset_document_caches : Nil
        @block_layouts.clear
        @layout_key = nil
        @doc_revision += 1
      end

      private def wire_document : Nil
        @ev_contents_change = document.on(Crysterm::Event::ContentsChange) do |e|
          on_contents_change(e.position, e.chars_removed, e.chars_added, e.kind)
        end
      end

      # Document edit hook: drop the layout cache entries of the blocks now
      # overlapping the changed range (their wrapped rows are stale) and
      # request a repaint. Untouched blocks keep their rows — that's what
      # makes an edit O(block). Format-only changes (including block-format
      # changes at a caret, which report `removed == added == 0`) land in the
      # same path: block format now drives the decoration width and thus the
      # wrap, so the touched blocks must re-wrap. Decoration-width fallout on
      # *other* blocks (list renumbering) is caught by `BlockLayout#deco`
      # comparison in `#rebuild_layout` instead.
      #
      # The caret also follows here: an edit made by another actor on a
      # shared document (a second view, a `TextCursor`, direct document
      # calls) shifts this view's caret/selection like a registered cursor
      # (see `DocumentBuffer#follow_document_change`); the widget's own edits
      # are skipped — the mixin moves the caret itself.
      private def on_contents_change(pos : Int32, removed : Int32, added : Int32, kind : TextDocument::ChangeKind) : Nil
        follow_document_change(kind, pos, removed, added)
        @doc_revision += 1
        blocks = document.blocks
        b1 = document.block_at(pos)[0]
        b2 = document.block_at(pos + added)[0]
        (b1..b2).each do |i|
          blocks[i]?.try { |b| @block_layouts.delete(b.object_id) }
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

      # Assembles `@_clines` (rows + fake/real maps) and `@row_meta` from
      # per-block layouts, wrapping only blocks without a cache entry (or
      # whose decoration width changed — see `BlockLayout`). The swap hash
      # keeps only blocks still in the document, so removed blocks' entries
      # are swept. Decorated blocks wrap at `colwidth - deco`; block margins
      # interleave blank rows that belong to the block (`rtof`) but carry no
      # buffer positions (absent from `ftor`, `RowMeta#margin` set), which
      # the shared geometry steps over.
      private def rebuild_layout(colwidth : Int32, key : Tuple(Int32, Int32, Bool, Int32)) : Nil
        @block_layouts.clear if key != @layout_key
        @layout_key = key
        @layout_revision = @doc_revision

        cl = @_clines
        cl.reset
        fake = cl.fake
        fake.clear
        meta = @row_meta
        meta.clear
        full_width = 0
        max_width = 0
        tier = glyph_tier
        # 0-based item counter per list instance (identity-keyed), advanced
        # in document order — the marker numbering source.
        list_items = {} of UInt64 => Int32

        fresh = @block_layouts_swap
        fresh.clear
        # Frame path of the previous block — boundary rows (frame borders)
        # are emitted where consecutive blocks' paths diverge.
        empty_path = [] of TextFrameFormat
        prev_path = empty_path
        document.blocks.each_with_index do |blk, bi|
          bf = blk.block_format
          marker = nil
          if lf = bf.list_format
            n = list_items[lf.object_id]? || 0
            list_items[lf.object_id] = n + 1
            marker = lf.marker(n, tier, bf.checked?)
          end
          deco = block_deco_cells(bf, marker)
          rdeco = frame_inset(bf)
          entry = @block_layouts[blk.object_id]?
          bl = entry && entry.deco == deco && entry.rdeco == rdeco ? entry.lines : wrap_block(blk, Math.max(colwidth - deco - rdeco, 2))
          fresh[blk.object_id] = BlockLayout.new(deco, rdeco, bl)

          # Frame boundary rows: close the frames the previous block was in
          # and this one isn't (bottom borders, innermost first, attached to
          # the previous block), then open this block's new frames (top
          # borders, outermost first). Borderless frames add no row.
          path = bf.frame_formats || empty_path
          unless path.same?(prev_path) || (path.empty? && prev_path.empty?)
            common = 0
            while common < prev_path.size && common < path.size && prev_path[common].same?(path[common])
              common += 1
            end
            (prev_path.size - 1).downto(common) do |i|
              next unless prev_path[i].border?
              cl.rtof << bi - 1
              meta << RowMeta.new(0, margin: true, fborder: {i, false})
              cl.push ""
            end
            (common...path.size).each do |i|
              next unless path[i].border?
              cl.rtof << bi
              meta << RowMeta.new(0, margin: true, fborder: {i, true})
              cl.push ""
            end
          end
          prev_path = path

          bf.top_margin.times do
            cl.rtof << bi
            meta << RowMeta.new(0, margin: true)
            cl.push ""
          end

          # Center/right alignment is a per-wrapped-row extra shift within
          # the space the decorations leave. Wrap mode only: non-wrap rows
          # are viewport slices of arbitrarily long lines, where alignment
          # has no stable meaning.
          align = bf.alignment
          align = nil unless wrap_content? && align && (align.h_center? || align.right?)
          avail = Math.max(colwidth - deco - rdeco, 0)

          row_ids = cl.take_ftor_row
          first = true
          bl.lines.each do |row|
            shift = 0
            if align
              slack = avail - str_width(row)
              shift = Math.max(align.h_center? ? slack // 2 : slack, 0)
            end
            row_ids << cl.size
            cl.rtof << bi
            meta << RowMeta.new(deco + shift, first ? marker : nil)
            cl.push row
            first = false
          end
          cl.ftor << row_ids
          fake << blk.text

          bf.bottom_margin.times do
            cl.rtof << bi
            meta << RowMeta.new(0, margin: true)
            cl.push ""
          end

          full_width = Math.max(full_width, bl.full_width + deco + rdeco)
          max_width = Math.max(max_width, bl.max_width + deco + rdeco)
        end
        # Close the frames still open past the last block (bottom borders,
        # innermost first).
        unless prev_path.empty?
          last_bi = document.block_count - 1
          (prev_path.size - 1).downto(0) do |i|
            next unless prev_path[i].border?
            cl.rtof << last_bi
            meta << RowMeta.new(0, margin: true, fborder: {i, false})
            cl.push ""
          end
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
      # and the non-wrap `_hslice` viewport window. `wrap_width` is the
      # column width left after the block's decorations. TABs are
      # pre-expanded exactly like `clean_content_chars` does, matching the
      # tab-expanded column units all the shared caret math runs in.
      private def wrap_block(blk : TextBlock, wrap_width : Int32) : CLines
        text = blk.text
        text = text.gsub('\t', style.tab_char * style.tab_size) if text.includes?('\t')
        _wrap_content(text, wrap_width)
      end

      # Decoration cells left of a block's text: frame insets (borders +
      # margins, outermost first), quote bars (2 per level), list nesting
      # indent, plain block indent, and the list marker.
      private def block_deco_cells(bf : TextBlockFormat, marker : String?) : Int32
        deco = frame_inset(bf) + bf.quote_level * 2 + bf.indent
        if lf = bf.list_format
          deco += (lf.indent - 1) * LIST_INDENT_CELLS
        end
        deco += str_width(marker) if marker
        deco
      end

      # Horizontal inset one side of a block's frame nesting consumes: 2
      # cells per bordered level (bar + gap) plus each level's margin. Frames
      # are symmetric, so this is both the left and the right inset.
      private def frame_inset(bf : TextBlockFormat) : Int32
        path = bf.frame_formats || return 0
        w = 0
        path.each { |f| w += (f.border? ? 2 : 0) + f.margin }
        w
      end

      # === Geometry hooks (see `Mixin::TextEditing`) ===

      # Where this row's text starts: the shared caret/mouse/selection math
      # adds it, `#paint_document` paints from it.
      private def row_text_x_offset(rl : Int32) : Int32
        @row_meta[rl]?.try(&.offset) || 0
      end

      # Steps over block-margin rows (no buffer positions) in the direction
      # of travel; when that runs off the edge, back the other way.
      private def nearest_text_row(rl : Int32, dir : Int32) : Int32
        r = rl
        while (m = @row_meta[r]?) && m.margin
          r += dir
        end
        if r < 0 || r >= @_clines.size
          r = rl
          while (m = @row_meta[r]?) && m.margin
            r -= dir
          end
        end
        r.clamp(0, Math.max(0, @_clines.size - 1))
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

        # First paintable viewport column: when the widget hangs off the left
        # screen edge `xi` is negative, and `line[xi + col]?` with a negative
        # index wraps to the row's right end (`Indexable#[]?`). The y loop
        # below guards rows the same way (`next if y < 0`).
        min_col = Math.max(0, -xi)

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
          meta = @row_meta[rl]?
          bi = @_clines.rtof[rl]? || next
          blk = document.blocks[bi]? || next

          # A margin row is pure spacing (the base fill painted it), but
          # frame chrome runs through it: enclosing frames' side bars, and —
          # on an `fborder` row — the frame's horizontal border with corners.
          if meta && meta.margin
            paint_frame_margin_row(line, xi, region_w, meta, blk.block_format.frame_formats, base_attr)
            next
          end

          if bi != last_bi
            last_bi = bi
            # Fragment formats with any `SyntaxHighlighter` overlay merged.
            runs = blk.render_runs
          end
          bfmt = blk.block_format
          block_bg = bfmt.bg
          heading = bfmt.heading?

          bp = document.block_position(bi)
          row_start = pos_from_rowcol(rl, 0)
          row_end = pos_from_rowcol(rl, line_display_width(rl))
          next if row_end < row_start

          sel_cols = selection_columns_for_row(rl)
          # `offset` (the row's decoration inset) must be hoisted above the call:
          # ranged extra selections are viewport columns and need it, matching
          # `selection_columns_for_row`'s `off + rendered_column(...)` convention
          # (BUGS15 #46).
          offset = meta.try(&.offset) || 0
          row_xsels, full_fmt = row_extra_selections(row_start, row_end, offset)

          paint_decorations(line, xi, region_w, meta, bfmt, base_attr, full_fmt, bch) if meta && offset > 0

          # Right-side frame bars sit at fixed columns from the region's
          # right edge; the wrap width already keeps text (and the bounded
          # fills below) off them.
          rin = frame_inset(bfmt)
          paint_frame_right_bars(line, xi, region_w, bfmt.frame_formats, base_attr) if rin > 0
          inner_r = region_w - rin

          if bfmt.horizontal_rule?
            # The whole row (past any decorations) is a rule glyph fill; the
            # block's own text is conventionally empty and not painted.
            rattr = deco_attr(theme.rule_color, base_attr, block_bg, full_fmt)
            rc = glyph(Glyphs::Role::LineHorizontal)
            c2 = Math.max(offset - @child_base_x, min_col)
            while c2 < inner_r
              line[xi + c2]?.try &.set_if_changed(rattr, rc)
              c2 += 1
            end
            next
          end

          raw = blk.text
          ls = row_start - bp
          le = row_end - bp
          row_text = (ls == 0 && le == raw.size) ? raw : raw[ls, le - ls]

          # Viewport column of the row text's first character: the row's
          # decoration offset, shifted left by the horizontal scroll when not
          # wrapping (the off-view prefix advances `col` without painting).
          col = offset - @child_base_x
          lp = ls # block-local codepoint offset (indexes `runs`)
          ri = 0  # current format run
          run_attr = base_attr
          run_link = 0_u16 # OSC 8 link id of the current run (see `Window#link_id`)
          run_hi = -1      # `lp` bound the cached `run_attr` is valid below

          each_glyph(row_text, fu) do |ch, cluster, cps|
            break if col >= region_w

            if lp >= run_hi
              while ri < runs.size && lp >= runs[ri][1]
                ri += 1
              end
              if ri < runs.size && lp >= runs[ri][0]
                run_hi = runs[ri][1]
                run_attr = pack_char_attr(runs[ri][2], base_attr, block_bg, heading)
                # Anchor runs also carry their target as a cell hyperlink, so
                # the draw loop emits OSC 8 around them (0 when links are off).
                run_link = (href = runs[ri][2].anchor_href) ? scr.link_id(href) : 0_u16
              else
                run_hi = Int32::MAX
                run_attr = pack_char_attr(nil, base_attr, block_bg, heading)
                run_link = 0_u16
              end
            end

            if ch == '\t'
              tab_expansion.each_char do |tc|
                break if col >= region_w
                if col >= min_col && (cell = line[xi + col]?)
                  cell.set_if_changed(overlay_attr(run_attr, col, sel_cols, row_xsels, full_fmt), tc)
                  cell.link = run_link
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
            if col >= min_col && (cell = line[x]?)
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
              # The link is re-asserted after every content write (which
              # clears it); painted after the write on purpose.
              cell.link = run_link
              painted_lead = true
            end

            if w == 2
              ncol = col + 1
              if ncol >= min_col && ncol < region_w && (nxt = line[x + 1]?)
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
                # A linked wide glyph covers both of its cells.
                nxt.link = run_link
              end
            end

            col += w
            lp += cps
          end

          # Trailing cells past the text: normally the base fill already
          # painted them, but a block background or a full-width extra
          # selection (current-line highlight) must extend to the region edge
          # (up to any frame's right inset).
          if block_bg || full_fmt
            trail = pack_char_attr(nil, base_attr, block_bg, heading)
            c2 = Math.max(col, min_col)
            while c2 < inner_r
              if cell = line[xi + c2]?
                cell.set_if_changed(overlay_attr(trail, c2, sel_cols, row_xsels, full_fmt), bch)
              end
              c2 += 1
            end
          end
        end
      end

      # Paints the row's decoration columns `[0, offset)`: enclosing frames'
      # left bars first (outermost at column 0), then quote bars, the list
      # marker right-aligned to the text's left edge (first row of its block
      # only), and — when the block carries a background or a full-width
      # overlay — the fill between them. Gap cells without either are left
      # to the base fill.
      private def paint_decorations(line, xi : Int32, region_w : Int32, meta : RowMeta, bfmt : TextBlockFormat, base_attr : Int64, full_fmt : TextCharFormat?, bch : Char) : Nil
        off = meta.offset
        block_bg = bfmt.bg
        marker = meta.marker
        mw = marker ? str_width(marker) : 0
        qcols = bfmt.quote_level * 2
        bar = glyph(Glyphs::Role::LineVertical)
        bar_attr = deco_attr(theme.quote_color, base_attr, block_bg, full_fmt)
        marker_attr = deco_attr(theme.heading_color, base_attr, block_bg, full_fmt)
        gap_attr = full_fmt ? merge_format_attr(pack_char_attr(nil, base_attr, block_bg, false), full_fmt) : pack_char_attr(nil, base_attr, block_bg, false)
        fill_gaps = block_bg || full_fmt
        # Columns left of the screen (negative `xi + vc`) must be skipped, not
        # wrapped to the row's right end (see `#paint_document`'s `min_col`).
        min_col = Math.max(0, -xi)

        # Frame region `[0, foff)`: one bar per bordered level; margins and
        # bar gaps stay on the base fill (frames sit outside the block's own
        # background).
        foff = 0
        if path = bfmt.frame_formats
          fattr = deco_attr(theme.rule_color, base_attr, nil, full_fmt)
          path.each do |f|
            if f.border?
              vc = foff - @child_base_x
              if vc >= min_col && vc < region_w && (cell = line[xi + vc]?)
                cell.set_if_changed(fattr, bar)
              end
            end
            foff += (f.border? ? 2 : 0) + f.margin
          end
        end

        (foff...off).each do |dcol|
          vc = dcol - @child_base_x
          next if vc < min_col
          break if vc >= region_w
          cell = line[xi + vc]? || next
          if dcol - foff < qcols && (dcol - foff).even?
            cell.set_if_changed(bar_attr, bar)
          elsif marker && dcol >= off - mw
            # Marker glyphs are single-width (bullets, digits, letters).
            cell.set_if_changed(marker_attr, marker[dcol - (off - mw)])
          elsif fill_gaps
            cell.set_if_changed(gap_attr, bch)
          end
        end
      end

      # Paints the right-side bars of a block's bordered frames — fixed
      # columns from the region's right edge (the mirror of the left bars in
      # `#paint_decorations`).
      private def paint_frame_right_bars(line, xi : Int32, region_w : Int32, path : Array(TextFrameFormat)?, base_attr : Int64) : Nil
        return unless path
        bar = glyph(Glyphs::Role::LineVertical)
        fattr = deco_attr(theme.rule_color, base_attr, nil, nil)
        # See `#paint_document`'s `min_col`: never index left of the screen.
        min_col = Math.max(0, -xi)
        off = 0
        path.each do |f|
          if f.border?
            vc = region_w - 1 - off
            if vc >= min_col && (cell = line[xi + vc]?)
              cell.set_if_changed(fattr, bar)
            end
          end
          off += (f.border? ? 2 : 0) + f.margin
        end
      end

      # Paints a positionless (margin/border) row's frame chrome. A plain
      # block-margin row inside frames gets the enclosing bordered frames'
      # side bars; an `fborder` row additionally draws frame *depth*'s
      # horizontal border line with corners, with only the frames *outside*
      # it running their bars through.
      private def paint_frame_margin_row(line, xi : Int32, region_w : Int32, meta : RowMeta, path : Array(TextFrameFormat)?, base_attr : Int64) : Nil
        return unless path && !path.empty?
        fattr = deco_attr(theme.rule_color, base_attr, nil, nil)
        bar = glyph(Glyphs::Role::LineVertical)
        # See `#paint_document`'s `min_col`: never index left of the screen.
        min_col = Math.max(0, -xi)
        depth = path.size
        border_of = nil.as(Tuple(Int32, Bool)?)
        if fb = meta.fborder
          depth = fb[0]
          border_of = fb
        end

        off = 0
        (0...depth).each do |i|
          f = path[i]
          if f.border?
            vc = off - @child_base_x
            if vc >= min_col && vc < region_w && (cell = line[xi + vc]?)
              cell.set_if_changed(fattr, bar)
            end
            vr = region_w - 1 - off
            if vr >= min_col && (cell = line[xi + vr]?)
              cell.set_if_changed(fattr, bar)
            end
          end
          off += (f.border? ? 2 : 0) + f.margin
        end

        if border_of
          l = off
          r = region_w - 1 - off
          return if r <= l
          top = border_of[1]
          lc = glyph(top ? Glyphs::Role::BorderLineTL : Glyphs::Role::BorderLineBL)
          rc = glyph(top ? Glyphs::Role::BorderLineTR : Glyphs::Role::BorderLineBR)
          h = glyph(Glyphs::Role::LineHorizontal)
          (l..r).each do |dcol|
            vc = dcol - @child_base_x
            next if vc < min_col
            break if vc >= region_w
            cell = line[xi + vc]? || next
            cell.set_if_changed(fattr, dcol == l ? lc : (dcol == r ? rc : h))
          end
        end
      end

      # Packed attr of a decoration glyph: *color* over the widget base (or
      # the block background), with any full-width overlay merged so a
      # current-line highlight spans the decorations too.
      private def deco_attr(color : Int32, base_attr : Int64, block_bg : Int32?, full_fmt : TextCharFormat?) : Int64
        bg = (b = block_bg) ? Attr.pack_color(b) : Attr.bg(base_attr)
        a = Attr.pack(Attr.flags(base_attr), Attr.pack_color(color), bg)
        full_fmt ? merge_format_attr(a, full_fmt) : a
      end

      # Yields the row's paint units: `{lead char, cluster string or nil,
      # codepoints consumed}`. Grapheme clusters under `full_unicode?` (a
      # cluster paints as one cell + continuation), single codepoints
      # otherwise (legacy: one codepoint per cell, width 1 — matching
      # `str_width`'s legacy accounting the layout ran with).
      private def each_glyph(text : String, fu : Bool, & : (Char, String?, Int32) ->) : Nil
        if fu
          text.each_grapheme do |g|
            # Read the stdlib-internal `@cluster` (`Char | String`) instead of
            # `g.to_s`, which allocates a fresh String for every (overwhelmingly
            # common) single-`Char` cluster. Mirrors `Unicode.width`'s idiom;
            # output is identical (a `String` cluster is always multi-codepoint).
            case cluster = g.@cluster
            in Char
              yield cluster, nil, 1
            in String
              yield cluster[0], cluster, cluster.size
            end
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
      private def row_extra_selections(row_start : Int32, row_end : Int32, offset : Int32 = 0) : Tuple(Array(Tuple(Range(Int32, Int32), TextCharFormat))?, TextCharFormat?)
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
              cols = (offset + rendered_column(row_start, s) - @child_base_x)...(offset + rendered_column(row_start, e) - @child_base_x)
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
      # cell model and is not rendered; anchors render underlined and carry
      # their target as a cell hyperlink (`run_link` above), which the draw
      # loop wraps in OSC 8 on supporting terminals — click *activation*
      # inside the TUI stays `TextBrowser` behavior.
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
      # TEXTEDIT.md the emacs default `C-y` stays yank) — plus the standard
      # Qt list-editing behaviors: Enter on an empty list item and Backspace
      # at an item's start take the block out of the list instead of
      # splitting/joining blocks, and typing a list marker auto-formats when
      # `#auto_formatting` enables it.
      def _listener(e)
        return if handle_undo_redo_key(e)

        # Table-aware routing: cell editing/navigation inside a table, and
        # the guards that keep outside edits from tearing the box rendering.
        return if !read_only? && table_guard(e)

        if !read_only? && (k = e.key)
          # Enter on an EMPTY list item exits the list (Qt: a return on an
          # empty item outdents it) rather than opening another empty item;
          # Backspace at the start of an item removes its bullet rather than
          # joining it into the previous block. Both are plain block-format
          # changes — one undo step, text untouched.
          empty_item_exit = k == Tput::Key::Enter && caret_block_empty_list_item?
          if !has_selection? && (empty_item_exit ||
             ((k == Tput::Key::Backspace || k == Tput::Key::CtrlH) && caret_at_list_item_start?))
            e.accept
            kill_ring.interrupt if Crysterm::Config.input_readline_keys
            clear_caret_list_membership
            _update_cursor
            return
          end
        end
        super
        auto_format_list(e) if !read_only? && !@auto_formatting.none?
      end

      # Whether the caret's block is an empty list item.
      private def caret_block_empty_list_item? : Bool
        bi, _ = document.block_at(@cursor_pos)
        blk = document.blocks[bi]
        blk.size == 0 && !blk.block_format.list_format.nil?
      end

      # Whether the caret sits at the very start of a list item's text.
      private def caret_at_list_item_start? : Bool
        bi, off = document.block_at(@cursor_pos)
        off == 0 && !document.blocks[bi].block_format.list_format.nil?
      end

      # Takes the caret's block out of its list (undoable); other block
      # formatting stays. The document change drives relayout/repaint.
      private def clear_caret_list_membership : Nil
        bi, _ = document.block_at(@cursor_pos)
        blk = document.blocks[bi]
        pos = document.block_position(bi)
        document.apply_block_format(pos, pos, blk.block_format.with_list_format(nil))
      end

      # The `#auto_formatting` hook, run after the shared key handling
      # inserted the typed character: a space completing a list marker at
      # the start of a plain block converts the block into a fresh
      # single-item list. Marker removal + list format are one edit block,
      # so a single undo restores the typed marker text.
      private def auto_format_list(e) : Nil
        return unless e.char == ' ' && e.key.nil?
        bi, off = document.block_at(@cursor_pos)
        return if off < 2
        blk = document.blocks[bi]
        bf = blk.block_format
        return if bf.list_format || bf.table_format || bf.horizontal_rule?
        prefix = blk.text[0, off]
        lf =
          if @auto_formatting.bullet_list? && prefix.matches?(/\A[-*+] \z/)
            TextListFormat.new(style: :disc)
          elsif @auto_formatting.numbered_list? && (m = prefix.match(/\A(\d{1,4})([.)]) \z/))
            TextListFormat.new(style: :decimal, start: m[1].to_i, number_suffix: m[2])
          end
        return unless lf
        bp = document.block_position(bi)
        document.begin_edit_block
        begin
          # Removing the marker pulls this view's caret back to the block
          # start via the shared caret follow (`follow_document_change` —
          # a direct document edit, not a `buf_*` self-edit).
          document.remove(bp, off)
          document.apply_block_format(bp, bp, TextBlockFormat.new(list_format: lf), merge: true)
        ensure
          document.end_edit_block
        end
        emit Crysterm::Event::TextChange, buf_text
        request_render
        _update_cursor
      end

      # === Table editing (TEXTEDIT.md follow-up: editable tables + cell
      # cursors). A `TextTable` is pre-rendered box-drawing blocks, so free
      # editing would tear it; instead, editing keys inside a table become
      # cell operations that re-render the padding through the table's
      # undoable API (`TextTable#set_cell_text` & co.). ===

      # The set of keys that edit content (vs. motion/copy) — what the table
      # guards act on. `Tab`/`Enter` get table meanings; the kill/yank/
      # clipboard-write keys have none and are absorbed inside a table.
      private def table_editing_key?(k : Tput::Key) : Bool
        k.in?(Tput::Key::Backspace, Tput::Key::CtrlH, Tput::Key::Delete,
          Tput::Key::Enter, Tput::Key::Tab, Tput::Key::ShiftTab,
          Tput::Key::CtrlX, Tput::Key::CtrlV, Tput::Key::CtrlW,
          Tput::Key::CtrlU, Tput::Key::CtrlK, Tput::Key::AltD,
          Tput::Key::CtrlY)
      end

      # Table-aware key routing. When the caret sits in a table: typing,
      # Backspace and Delete edit the caret's cell (padding re-rendered, one
      # undo step per keystroke); Tab/Shift-Tab move between cells — Tab past
      # the last cell appends a row (Qt behavior); Enter inserts a row below;
      # cut/paste/kill/yank are absorbed. From outside: a selection
      # overlapping table blocks absorbs content edits (a partial-table
      # delete would corrupt the rendering), and Backspace/Delete at a
      # table's edge won't join a neighbor block into a border row. Motion,
      # copy and undo always pass through. Returns whether the key was
      # consumed.
      private def table_guard(e) : Bool
        k = e.key
        typing = k.nil? && (c0 = e.char) && !c0.to_s.matches?(/\A[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]\z/)
        return false unless typing || (k && table_editing_key?(k))

        tbl = caret_table
        if tbl.nil?
          if has_selection?
            return false unless selection_touches_table?
            e.accept
            kill_ring.interrupt if Crysterm::Config.input_readline_keys
            return true
          end
          # Boundary: joining a neighbor block into a border row is blocked.
          bi, off = document.block_at(@cursor_pos)
          if (k == Tput::Key::Backspace || k == Tput::Key::CtrlH) && off == 0 && bi > 0 &&
             document.blocks[bi - 1].block_format.table_format
            e.accept
            return true
          end
          if k == Tput::Key::Delete && off == document.blocks[bi].size &&
             document.blocks[bi + 1]?.try(&.block_format.table_format)
            e.accept
            return true
          end
          return false
        end

        e.accept
        kill_ring.interrupt if Crysterm::Config.input_readline_keys
        # A selection inside/into a table: content edits are absorbed (copy
        # via C-c still passes — it is not an editing key).
        return true if has_selection?

        info = tbl.cell_at(@cursor_pos)
        before = buf_text
        case k
        when Tput::Key::Tab      then table_tab(tbl, info, 1)
        when Tput::Key::ShiftTab then table_tab(tbl, info, -1)
        when Tput::Key::Enter    then table_insert_row_below(tbl, info)
        when Tput::Key::Backspace, Tput::Key::CtrlH
          table_delete_char(tbl, info, backward: true)
        when Tput::Key::Delete
          table_delete_char(tbl, info, backward: false)
        when nil
          if c = e.char
            c == '\t' ? table_tab(tbl, info, 1) : table_type_char(tbl, info, c)
          end
        else
          # Kill/yank/cut/paste inside a table: absorbed.
        end
        after = buf_text
        emit Crysterm::Event::TextChange, after if after != before
        request_render
        _update_cursor
        true
      end

      # The table the caret's block belongs to, or nil.
      private def caret_table : TextTable?
        bi, _ = document.block_at(@cursor_pos)
        tf = document.blocks[bi].block_format.table_format || return nil
        TextTable.new(document, tf)
      end

      # Whether the live selection overlaps any table block.
      private def selection_touches_table? : Bool
        r = selection_range || return false
        b1 = document.block_at(r.begin)[0]
        b2 = document.block_at(r.end)[0]
        (b1..b2).any? { |i| !document.blocks[i].block_format.table_format.nil? }
      end

      # Moves the caret *dir* cells (±1), wrapping across rows; Tab past the
      # last cell appends a fresh row (Qt), Shift-Tab before the first stays.
      # From a border row (no cell), lands on the first cell.
      private def table_tab(tbl : TextTable, info : {Int32, Int32}?, dir : Int32) : Nil
        unless info
          place_caret_in_cell(tbl, 0, 0, Int32::MAX)
          return
        end
        row, col = info
        col += dir
        if col >= tbl.columns
          col = 0
          row += 1
          tbl.insert_row(row) if row >= tbl.rows
        elsif col < 0
          return if row == 0
          row -= 1
          col = tbl.columns - 1
        end
        place_caret_in_cell(tbl, row, col, Int32::MAX)
      end

      # Enter inside a cell: a fresh row below the caret's (below the header
      # when pressed there), caret to its first cell.
      private def table_insert_row_below(tbl : TextTable, info : {Int32, Int32}?) : Nil
        return unless info
        at = Math.max(info[0] + 1, 1)
        tbl.insert_row(at)
        place_caret_in_cell(tbl, at, 0, 0)
      end

      # Types *c* into the caret's cell at the caret's offset.
      private def table_type_char(tbl : TextTable, info : {Int32, Int32}?, c : Char) : Nil
        return unless info
        row, col = info
        r = tbl.cell_text_range(row, col) || return
        off = (@cursor_pos - r.begin).clamp(0, r.end - r.begin)
        txt = tbl.cell_text(row, col) || ""
        tbl.set_cell_text(row, col, txt.insert(off, c))
        place_caret_in_cell(tbl, row, col, off + 1)
      end

      # Backspace/Delete within the caret's cell; a no-op at the cell's
      # start/end (cells never join).
      private def table_delete_char(tbl : TextTable, info : {Int32, Int32}?, backward : Bool) : Nil
        return unless info
        row, col = info
        r = tbl.cell_text_range(row, col) || return
        len = r.end - r.begin
        off = (@cursor_pos - r.begin).clamp(0, len)
        txt = tbl.cell_text(row, col) || ""
        if backward
          return if off <= 0
          tbl.set_cell_text(row, col, txt[0, off - 1] + txt[off..])
          place_caret_in_cell(tbl, row, col, off - 1)
        else
          return if off >= len
          tbl.set_cell_text(row, col, txt[0, off] + txt[off + 1..])
          place_caret_in_cell(tbl, row, col, off)
        end
      end

      # Parks the caret at *offset* within cell (*row*, *col*)'s text
      # (clamped — pass `Int32::MAX` for "end of cell").
      private def place_caret_in_cell(tbl : TextTable, row : Int32, col : Int32, offset : Int32) : Nil
        if r = tbl.cell_text_range(row, col)
          @cursor_pos = r.begin + offset.clamp(0, r.end - r.begin)
        end
        clear_selection
        @goal_col = nil
        ensure_cursor_visible
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

      # === Interchange (Qt setMarkdown/setHtml counterparts; TEXTEDIT.md
      # Phase 3). Each set replaces the document content wholesale — not
      # undoable, caret to the start (Qt behavior; contrast `#value=`, whose
      # plain-text convention parks the caret at the end). The document's
      # `ContentsChange` drives relayout, so no display work happens here. ===

      {% for f in %w(tags markdown html) %}
        # Replaces the content from {{f.id}} markup (see `TextDocument#set_{{f.id}}`).
        def set_{{f.id}}(str : String) : Nil
          document.set_{{f.id}}(str)
          interchange_reset_caret
        end

        # :ditto:
        def {{f.id}}=(str : String) : String
          set_{{f.id}}(str)
          str
        end

        # The content as {{f.id}} markup (see `TextDocument#to_{{f.id}}`).
        def to_{{f.id}} : String
          document.to_{{f.id}}
        end
      {% end %}

      private def interchange_reset_caret : Nil
        @cursor_pos = 0
        clear_selection
        @goal_col = nil
        @typing_format = nil
      end
    end
  end
end
