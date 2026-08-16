module Crysterm
  class Widget
    class TextEdit
      # === Render ===

      def paint(*, with_children = true)
        # Relayout before following the caret: `ensure_cursor_visible` maps
        # the caret through `@wrapped_lines`, which a document edit just staled.
        process_content
        if @rendered_revision != @doc_revision
          @rendered_revision = @doc_revision
          # A shrinking document may leave the viewport past the end.
          clamp_child_base_to_content
          # Follow the caret after an edit (not on every frame — a wheel/bar
          # scroll away from the caret must stick).
          _type_scroll
        end
        ret = base_render with_children
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
        lines_buf = scr.cell_rows
        fu = scr.full_unicode_effective?

        xi = coords.xi
        xl = coords.xl
        yi = coords.yi
        yl = coords.yl
        # Effective per-edge insets: when scroll-clipped by an enclosing
        # viewport, part of the border/padding band is hidden past that
        # viewport (recorded in `coords.hidden_*`), so the inset still to
        # apply is only each band's visible remainder — subtracting the full
        # border+padding would double-count the clipped rows/columns and start
        # the document too far in. Mirrors base_render's per-edge treatment.
        sb = style.border
        pd = style.padding
        ebt, ept = effective_edge_insets(sb.top, pd.top, coords.hidden_top)
        ebb, epb = effective_edge_insets(sb.bottom, pd.bottom, coords.hidden_bottom)
        ebl, epl = effective_edge_insets(sb.left, pd.left, coords.hidden_left)
        ebr, epr = effective_edge_insets(sb.right, pd.right, coords.hidden_right)
        xi += ebl + epl
        xl -= ebr + epr
        yi += ebt + ept
        yl -= ebb + epb
        yl -= hscrollbar_rows
        region_w = xl - xi
        return if region_w <= 0 || yl <= yi

        # First paintable viewport column: when the widget hangs off the left
        # screen edge `xi` is negative, and `line[xi + col]?` with a negative
        # index wraps to the row's right end (`Indexable#[]?`). The y loop
        # below guards rows the same way (`next if y < 0`).
        min_col = Math.max(0, -xi)

        base_attr = @_parse_attr_default || style_to_attr(style)
        # One raw TAB paints as this whole string (`tab_char` may be several
        # codepoints) — the same expansion the layout/caret math uses.
        tab_expansion = style.tab_char * style.tab_size
        bch = style.fill_char

        last_bi = -1
        runs = [] of Tuple(Int32, Int32, TextCharFormat)

        # Incremental row-bounds state, carried from the previously *measured*
        # row: `{block, real row, that row's `row_end`, its tab-expanded width
        # from the block start}`. The next row reuses it iff it is the very next
        # real row of the SAME block, in which case `row_start == carry_end`.
        #
        # Why that is exact — `#rebuild_layout` pushes one block's wrapped text
        # rows in a single tight loop (`bl.lines.each`), so they are contiguous
        # in `rl` AND in the order `ftor[bi]` lists them; every other row it
        # pushes (frame border rows, top/bottom block margins) is flagged
        # `RowMeta#margin` and is absent from `ftor`. Margin rows therefore
        # never sit *between* two text rows of one block, and the loop below
        # `next`s on them (at `meta.margin`) before any bounds are measured, so
        # they never update the carry either. Every other early `next`
        # (`y < 0`, a missing `lines_buf[y]`, `rl` out of range, an unmapped
        # `rtof`/`blocks` lookup) likewise leaves the carry alone, and the
        # `rl == carry_rl + 1` test then fails on the row after it, forcing the
        # exact re-seed. So a carry hit means both rows are text rows of `bi`,
        # adjacent in `ftor[bi]` — exactly the case where a fresh
        # `pos_from_rowcol(rl, 0)` would re-sum the same piece widths the previous
        # iteration's `row_end` already accounted for. TABs need no special
        # case: the carry passes *expanded* widths, the same units
        # `pos_from_rowcol` accumulated, and `unexpand_col_in` maps them back.
        carry_bi = -1
        carry_rl = -1
        carry_end = 0
        carry_exp = 0

        (yi...yl).each do |y|
          next if y < 0
          break if y >= scr.aheight
          line = lines_buf[y]? || next

          rl = coords.base + (y - yi)
          next if rl < 0 || rl >= @wrapped_lines.size
          meta = @row_meta[rl]?
          bi = @wrapped_lines.rtof[rl]? || next
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
          # `{bp, blk_end}` IS `buf_line_bounds(bi)` — a logical line is exactly
          # one block — already in hand, so the bounds below inline
          # `pos_from_rowcol`'s tail (`base + unexpand_col_in(...)`, clamped by
          # construction into `bp..blk_end`) around the carried prefix width.
          blk_end = bp + blk.size
          if carry_bi == bi && carry_rl == rl - 1
            exp_prefix = carry_exp
            row_start = carry_end
          else
            # Re-seed: one walk over the block's pieces preceding `rl` (what
            # `pos_from_rowcol` did per bound, per row).
            exp_prefix = 0
            if reals = @wrapped_lines.ftor[bi]?
              reals.each do |r|
                break if r >= rl
                exp_prefix += (@wrapped_lines[r]? || "").size
              end
            end
            row_start = bp + unexpand_col_in(bp, blk_end, exp_prefix)
          end
          exp_next = exp_prefix + line_display_width(rl)
          row_end = bp + unexpand_col_in(bp, blk_end, exp_next)
          carry_bi, carry_rl, carry_end, carry_exp = bi, rl, row_end, exp_next
          next if row_end < row_start

          # 3-arg form: `row_start`/`row_end` are exactly the bounds the 1-arg
          # form would recompute. Safe here because `TextEdit` does not override
          # `selection_columns_for_row` (`LineEdit` does, but has its own paint
          # path through `Widget#base_render`, which keeps calling the 1-arg form).
          sel_cols = selection_columns_for_row(rl, row_start, row_end)
          # `offset` (the row's decoration inset) must be hoisted above the call:
          # ranged extra selections are viewport columns and need it, matching
          # `selection_columns_for_row`'s `off + rendered_column(...)` convention.
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

          # Viewport column of the row text's first character: the row's
          # decoration offset, shifted left by the horizontal scroll when not
          # wrapping (the off-view prefix advances `col` without painting).
          col = offset - @child_base_x
          lp = ls # block-local codepoint offset (indexes `runs`)
          ri = 0  # current format run
          run_attr = base_attr
          run_link = 0_u16 # OSC 8 link id of the current run
          run_hi = -1      # `lp` bound the cached `run_attr` is valid below

          # Iterate the row's codepoint window `[ls, le)` straight out of the
          # block's `raw` text instead of slicing a fresh per-frame `String`
          # for every wrapped/scrolled row. `ls`/`le` are wrap cut
          # points, hence grapheme boundaries, so windowing the full walk
          # yields the exact clusters the substring would have.
          each_glyph(raw, fu, ls, le) do |ch, cluster, cps|
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
                # continuation" invariant (same safeguard as `base_render`).
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
      # `TextTheme` (allowed for import/export theming, not for this widget's
      # own painting) carries no per-alert-kind colors, so the GFM alert
      # accents are a small local table instead — chosen to echo github.com's
      # own alert border colors (blue/green/purple/yellow/red).
      ALERT_COLORS = {
        TextBlockFormat::AlertKind::Note      => 0x58A6FF,
        TextBlockFormat::AlertKind::Tip       => 0x3FB950,
        TextBlockFormat::AlertKind::Important => 0xA371F7,
        TextBlockFormat::AlertKind::Warning   => 0xD29922,
        TextBlockFormat::AlertKind::Caution   => 0xF85149,
      }

      private def paint_decorations(line, xi : Int32, region_w : Int32, meta : RowMeta, bfmt : TextBlockFormat, base_attr : Int64, full_fmt : TextCharFormat?, bch : Char) : Nil
        off = meta.offset
        block_bg = bfmt.bg
        marker = meta.marker
        mw = marker ? str_width(marker) : 0
        qcols = bfmt.quote_level * 2
        bar = glyph(Glyphs::Role::LineVertical)
        # An alert block's bar and title chip both take the kind's accent
        # color in place of the ordinary quote/marker colors — the "distinct
        # color per kind" GitHub's alert admonitions use.
        alert_color = (k = bfmt.alert_kind) ? ALERT_COLORS[k] : nil
        bar_attr = deco_attr(alert_color || theme.quote_color, base_attr, block_bg, full_fmt)
        marker_attr = deco_attr(alert_color || theme.heading_color, base_attr, block_bg, full_fmt)
        if alert_color
          marker_attr = Attr.pack(Attr.flags(marker_attr) | Attr::BOLD, Attr.fg(marker_attr), Attr.bg(marker_attr))
        end
        gap_attr = full_fmt ? full_fmt.merge_onto(pack_char_attr(nil, base_attr, block_bg, false)) : pack_char_attr(nil, base_attr, block_bg, false)
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
        full_fmt ? full_fmt.merge_onto(a) : a
      end

      # Yields the row's paint units: `{lead char, cluster string or nil,
      # codepoints consumed}`. Grapheme clusters under `full_unicode?` (a
      # cluster paints as one cell + continuation), single codepoints
      # otherwise (legacy: one codepoint per cell, width 1 — matching
      # `str_width`'s legacy accounting the layout ran with).
      # `cp_lo`/`cp_hi` window the walk to the codepoint range `[cp_lo, cp_hi)`
      # (default: the whole string), so `#paint_document` can drive it straight
      # from the block's `raw` text without slicing out a per-row substring.
      private def each_glyph(text : String, fu : Bool, cp_lo : Int32 = 0, cp_hi : Int32 = Int32::MAX, & : (Char, String?, Int32) ->) : Nil
        if fu
          # Grapheme clustering is context-sensitive, and skipping a prefix by
          # re-walking it costs more than the slice it would replace — so for a
          # windowed row still materialize the substring (`raw[ls, le-ls]`),
          # keeping the no-alloc fast path only for a full row.
          gtext = (cp_lo == 0 && cp_hi >= text.size) ? text : text[cp_lo, cp_hi - cp_lo]
          gtext.each_grapheme do |g|
            # Read the stdlib-internal `@cluster` (`Char | String`) rather than
            # `g.to_s`, which allocates a fresh String for every (overwhelmingly
            # common) single-`Char` cluster. Output is identical: a `String`
            # cluster is always multi-codepoint.
            case cluster = g.@cluster
            in Char
              yield cluster, nil, 1
            in String
              yield cluster[0], cluster, cluster.size
            end
          end
        else
          # Legacy (one codepoint per cell): window the block text directly, no
          # per-row substring allocation.
          cp = 0
          text.each_char do |c|
            break if cp >= cp_hi
            yield c, nil, 1 if cp >= cp_lo
            cp += 1
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
          elsif xs.full_width && c.position >= row_start && c.position <= row_end
            full_fmt = full_fmt ? full_fmt.merge(xs.format) : xs.format
          end
        end
        {ranged, full_fmt}
      end

      # The packed attr of one char: widget base attr + block background/
      # heading + the char format's SGR set (via
      # `TextCharFormat#apply_to_attr`). Anchors render underlined and carry
      # their target as a cell hyperlink (`run_link` above), which the draw
      # loop wraps in OSC 8 on supporting terminals — click *activation*
      # inside the TUI stays `TextBrowser` behavior.
      private def pack_char_attr(fmt : TextCharFormat?, base_attr : Int64, block_bg : Int32?, heading : Bool) : Int64
        flags = Attr.flags(base_attr)
        fg = Attr.fg(base_attr)
        bg = (bbg = block_bg) ? Attr.pack_color(bbg) : Attr.bg(base_attr)
        flags |= Attr::BOLD if heading
        attr = Attr.pack(flags, fg, bg)
        fmt ? fmt.apply_to_attr(attr) : attr
      end

      # *attr* with this cell's overlays applied: extra selections (format
      # patches, mask-aware), then the mouse/keyboard selection highlight
      # (reverse video, same as the base render's `highlighted_attr`).
      private def overlay_attr(attr : Int64, col : Int32, sel_cols : Range(Int32, Int32)?, row_xsels : Array(Tuple(Range(Int32, Int32), TextCharFormat))?, full_fmt : TextCharFormat?) : Int64
        if f = full_fmt
          attr = f.merge_onto(attr)
        end
        row_xsels.try &.each do |(cols, f)|
          attr = f.merge_onto(attr) if cols.includes?(col)
        end
        highlighted_attr(attr, sel_cols, col)
      end
    end
  end
end
