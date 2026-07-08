module Crysterm
  class Widget
    # module Rendering
    include Crystallabs::Helpers::Alias_Methods

    # Per-widget override of the overflow action; `nil` = inherit. Read through
    # `#overflow`, which falls back to the window default (`Config.window_overflow`)
    # when unset. Set via `#overflow=` (an `Overflow`, a shorthand, or `nil`).
    @overflow : Overflow? = nil

    # Reused stops set for `#dock_rows`, cleared per call, so the per-frame
    # docking of a menu's separator rows doesn't allocate a fresh Hash each
    # frame (D1). Lazily allocated on first use (many widgets never dock rows).
    @_dock_rows_stops : Hash(Int32, Bool)? = nil

    # Action when this widget overflows its parent's rectangle: the per-widget
    # override if set, else the window default (`Overflow::Ignore` if window-less).
    def overflow : Overflow
      @overflow || window?.try(&.overflow) || Overflow::Ignore
    end

    # The raw per-widget override (`nil` = inheriting the window default).
    # Distinct from `#overflow`, which resolves the inherited value.
    def own_overflow : Overflow?
      @overflow
    end

    def overflow=(value : Overflow?)
      @overflow = value
    end

    def overflow=(value : ::Crystallabs::Helpers::Enums::Shorthands)
      @overflow = ::Crystallabs::Helpers::Enums.from(Overflow, value)
    end

    # Layout engine arranging this widget's children, or nil for manual placement
    # (children use their own coordinates). When nil, `#_render` falls back to
    # `Layout::Manual`. Mirrors Qt's null `QWidget::layout()`.
    property layout : Crysterm::Layout? = nil

    # Optional per-child hint read by this widget's *parent's* layout engine
    # (Border region, Grid cell+span, flex grow factor). See `Crysterm::Layout::Hint`.
    property layout_hint : Crysterm::Layout::Hint? = nil

    # `Box.render` sets `lpos` (rendered coordinates) on the element. Stale if
    # later moved, but otherwise more accurate than recalculating: a parent
    # always renders before its children, so the parent's `lpos` can be reused
    # instead of recomputing (which mishandles content shrinkage).

    property items = [] of Widget::Box

    # True only while this widget renders as a layer root into its own `Plane`
    # (see `Window#composite_planes`). Translucency then comes from the plane's
    # opacity, so the render-time alpha self-blend is suppressed.
    property compositing = false

    # Resolves the `Style` a *child* should render with. Base returns the child's
    # own style; containers that style children (e.g. `Widget::List` highlighting
    # the selected row) override this. Called on the child's parent from `#_render`.
    def render_style_for(item : Widget) : Style
      item.style
    end

    # Column range (`x - xi` units, half-open) on real (post-wrap) line *rl*
    # that `#_render` should paint with the selection highlight, or `nil` for
    # none. A free no-op on every widget; `Mixin::TextEditing` overrides it
    # while a mouse selection is active. Checked once per row, not per cell.
    protected def selection_columns_for_row(rl : Int32) : Range(Int32, Int32)?
      nil
    end

    # *attr* with the selection highlight applied (reverse video, the same
    # idiom `Window#_artificial_cursor_attr` uses for the block cursor) when
    # *col* falls inside *sel_cols*, else *attr* unchanged. `sel_cols` is `nil`
    # on every widget without an active selection, so this is a single
    # comparison in the common case. Never mutates the SGR-tracking `attr`
    # local in `#_render`'s loop — only the value actually painted to the cell.
    @[AlwaysInline]
    private def highlighted_attr(attr : Int64, sel_cols : Range(Int32, Int32)?, col : Int32) : Int64
      return attr unless sel_cols && sel_cols.includes?(col)
      Attr.pack(Attr.flags(attr) | Attr::REVERSE, Attr.fg(attr), Attr.bg(attr))
    end

    # Renders all child elements into the output buffer.
    # ameba:disable Metrics/CyclomaticComplexity
    def _render(with_children = true)
      emit Crysterm::Event::PreRender

      # Let the parent dictate this widget's render style (a list highlights its
      # selected row); an ordinary parent just hands back our own style.
      # `own_style` lets `default_attr` below detect when the render style IS our
      # own and reuse the `sattr` from `process_content`.
      own_style = self.style
      style = parent.try(&.render_style_for(self)) || own_style

      # Keep any border label glued to the (possibly CSS-resolved) top inset.
      # Must run before the label child renders.
      sync_label_position

      # `awidth(true)` is an O(1) read of the parent's already-rendered cached
      # `lpos`. Resolve once and pass to both `process_content` and `_get_coords`
      # instead of each walking the ancestor chain (O(depth)) separately.
      aw = awidth(true)
      process_content awidth_hint: aw

      # Pass `@lpos` so `_get_coords` updates it in place rather than allocating a
      # fresh `LPos` every frame. Nil on first render, then it allocates.
      coords = _get_coords(true, into: @lpos, width_hint: aw)
      unless coords
        @lpos = nil
        return
      end

      if coords.xl - coords.xi <= 0
        coords.xl = Math.max(coords.xl, coords.xi)
        return
      end

      if coords.yl - coords.yi <= 0
        coords.yl = Math.max(coords.yl, coords.yi)
        return
      end

      # `window` walks the parent chain on every call; bind it once. `full_unicode?`,
      # `style.alpha?` and `style.padding` are constant for the render, so hoist
      # them rather than re-evaluating in the per-cell loops below.
      scr = window
      # No-op unless an `animation` is declared.
      ensure_css_animation

      lines = scr.lines
      fu = scr.full_unicode?
      # A layer root's alpha is applied as its plane's opacity at composite time,
      # so suppress the render-time self-blend while painting into the plane.
      style_alpha = @compositing ? nil : style.alpha?
      padding = style.padding
      # Hoisted out of the content loop, which read it per cell.
      fill = style.fill?
      xi = coords.xi
      xl = coords.xl
      yi = coords.yi
      yl = coords.yl
      # `#pcontent` materializes the printable string if a deferred append left it
      # stale, caching into `@_pcontent`. Once per frame, not per appended line.
      pcontent = self.pcontent
      # Reuse the cached codepoint index unless `@_pcontent` was reparsed into a
      # fresh `String` (identity check) — otherwise re-scan and rebuild.
      content = @_content_index
      unless content && content.built_from?(pcontent)
        content = StringIndex.new pcontent
        @_content_index = content
      end
      ci = @_clines.ci[coords.base]? || 0 # XXX Is it ok that array lookup can be nil? and defaulting to 0?
      bch = style.fill_char

      # D O:
      # Clip content if it's off the edge of the window
      # if (xi + ileft < 0 || yi + itop < 0)
      #   clines = @_clines.slice()
      #   if (xi + ileft < 0)
      #     for (i = 0; i < clines.size; i++)
      #       t = 0
      #       csi = ''
      #       csis = ''
      #       for (j = 0; j < clines[i].size; j++)
      #         while (clines[i][j] == '\e')
      #           csi = '\e'
      #           while (clines[i][j++] != 'm') csi += clines[i][j]
      #           csis += csi
      #         end
      #         if (++t == -(xi + ileft) + 1) break
      #       end
      #       clines[i] = csis + clines[i].substring(j)
      #     end
      #   end
      #   if (yi + itop < 0)
      #     clines = clines.slice(-(yi + itop))
      #   end
      #   content = clines.join('\n')
      # end

      if coords.base >= @_clines.ci.size
        # Can be @_pcontent, but this is the same here, plus not_nil!
        ci = content.size
      end

      @lpos = coords

      register_dock_stops coords

      # `process_content` already cached `sattr(self.style)` in `@_parse_attr_default`.
      # When the render style IS our own (vs. a parent substituting one, e.g. a
      # `List` highlighting its selection), reuse it instead of repacking the
      # same fields again. `|| sattr(style)` is a defensive fallback.
      default_attr = (style.same?(own_style) ? @_parse_attr_default : nil) || sattr(style)
      attr = default_attr

      # If we're in a scrollable text box, check to
      # see which attributes this line starts with.
      if ci > 0
        attr = @_clines.attr.try(&.[Math.min(coords.base, @_clines.size - 1)]?) || default_attr
      end

      style.border.try do |border|
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl
      end

      # Reserve the bottom row(s) for a shown horizontal scroll bar so content
      # never paints under it. `may_scroll` skips this for the common
      # non-scrollable case, but still reconciles a widget that *was* scrollable
      # so its bar gets hidden when scrolling is turned off. `hsr` is reused by
      # the restore below. (Computed here, before the pre-fill, which needs it
      # to size the bottom band.)
      may_scroll = scrollable? || !@scrollbar_widget.nil? || !@horizontal_scrollbar_widget.nil?
      hsr = may_scroll ? hscrollbar_rows : 0

      # Padding/valign make the content loop skip some cells/lines, so fill
      # those ahead of time. On the common opaque-fill path only the cells the
      # content loop won't visit need pre-filling: the padding bands and the
      # scrollbar-reserved rows (the loop paints the valign gap itself — a
      # negative `ci` indexes to nil, i.e. the `bch` fill). A background-image
      # widget keeps the whole-box fill (its content loop leaves empty cells
      # untouched for the image). A `fill: false` widget draws no background at
      # all, so it must NOT be filled here either — see the final `else`.
      if padding.any? || !@align.top?
        if alpha = style_alpha
          # The content loop below already alpha-blends every cell of the
          # (padding/hsr-inset) content region, so blending those cells here too
          # would double-blend them — making a padded or vertically-aligned
          # translucent widget's interior more opaque than its own padding (and
          # than an unpadded translucent widget). Pre-blend only the bands the
          # content loop won't reach; skip the content region. Exception: a
          # background-image widget's content loop leaves empty cells untouched,
          # so there the whole-box blend must stay (bands + interior).
          pd = padding
          skip_content = style.background_image.nil?
          cxi = xi + pd.left
          cxl = xl - pd.right
          cyi = yi + pd.top
          cyl = yl - pd.bottom - hsr
          (Math.max(yi, 0)...yl).each do |y|
            line = lines[y]?
            unless line
              break
            end
            in_crow = skip_content && (y >= cyi) && (y < cyl)
            (Math.max(xi, 0)...xl).each do |x|
              # Inside the content region: the content loop handles the blend.
              next if in_crow && (x >= cxi) && (x < cxl)
              cell = line[x]?
              unless cell
                break
              end
              cell.attr = Colors.blend(attr, cell.attr, alpha: alpha)
              # cell.char = bch
              line.mark_dirty x
            end
          end
        elsif fill && style.background_image.nil?
          pd = padding
          bot = pd.bottom + hsr
          # Degenerate boxes (padding thicker than the box) make bands overlap
          # or ranges invert; `fill_region` clamps and empty ranges no-op, and a
          # double-filled cell is change-skipped on the second write.
          scr.fill_region(default_attr, bch, xi, xl, yi, yi + pd.top) if pd.top > 0
          scr.fill_region(default_attr, bch, xi, xl, yl - bot, yl) if bot > 0
          scr.fill_region(default_attr, bch, xi, xi + pd.left, yi + pd.top, yl - bot) if pd.left > 0
          scr.fill_region(default_attr, bch, xl - pd.right, xl, yi + pd.top, yl - bot) if pd.right > 0
        else
          # Reached for a background-image widget (`fill` true, image present —
          # the image paints over this base fill) or a `fill: false` widget.
          # `fill: false` means "draw no background": the content loop skips
          # every cell, and the no-padding/top-aligned path skips this whole
          # block, leaving the widget transparent. Filling here would make it
          # opaque *only* when it happens to have padding or vertical alignment
          # — an inconsistency where those properties silently toggle the
          # background. Gate on `fill` so a `fill: false` widget stays
          # transparent regardless; the background-image branch is unaffected.
          scr.fill_region(default_attr, bch, xi, xl, yi, yl) if fill
        end
      end

      # Background image (CSS `background-image`): paint the internal `Media`
      # layer before the content loop so text draws on top (see
      # `widget_background.cr`). `bg_cells` tells the content loop to leave
      # empty cells showing the image when a `Media::Cells` layer paints the buffer.
      update_background_media
      bg_cells = background_paints_cells?

      p = padding
      xi, xl, yi, yl = p.adjust xi, xl, yi, yl
      yl -= hsr

      # Determine where to place the text if it's vertically aligned.
      if @align.v_center? || @align.bottom?
        visible = yl - yi
        if @_clines.size < visible
          if @align.v_center?
            visible = visible // 2
            visible -= @_clines.size // 2
          elsif @align.bottom?
            visible -= @_clines.size
          end
          ci -= visible * (xl - xi)
        end
      end

      # Whether this widget is the selected item of a parent list, in which case
      # content keeps the default foreground (only bg/flags follow inline SGR).
      # Resolved once here instead of re-walking the parent chain per SGR escape.
      keep_selected_fg = parent.try do |parent2|
        parent2._is_list && parent2.interactive? && parent2.item_selected?(self) # XXX && parent2.invert_selected
      end || false

      # Whether a row whose content is exhausted may be painted as one
      # `fill_region` sweep instead of walking the full per-cell machinery (the
      # very common "large box, little content" case — most cells on screen are
      # fill cells). Requires the constant `{attr, bch}` write to be exactly
      # what the per-cell path does — everything except the alpha blend, which
      # keeps the per-cell path. (Even a wide `bch` matches: fill cells have
      # `has_content == false`, so the per-cell path never measures/clusters
      # them either — one glyph per cell, no continuation claim.) Selection is
      # checked per row (`sel_cols`); it can't actually reach rows past the
      # content end, so that guard is defensive.
      bulk_fill_ok = style_alpha.nil?

      # Draw the content and background.
      (yi...yl).each do |y|
        line = lines[y]?
        unless line
          if y >= scr.aheight || yl < ibottom
            break
          else
            next
          end
        end
        # Rows above the top edge (`y < 0`) must still be walked so the content
        # index advances, but NOT painted: `Indexable#[]?` counts a negative
        # index from the END, so writing there corrupts the window bottom (same
        # hazard per-cell for `x < 0`). `draw_row` and the `x < 0`/`target`
        # guards gate every write.
        draw_row = y >= 0

        # Text-selection highlight (`Mixin::TextEditing`): resolved once per
        # row, not per cell — a free `nil` on every widget without a selection.
        # `y - yi` assumes top alignment, like `#selection_columns_for_row`'s
        # own doc notes.
        sel_cols = selection_columns_for_row(coords.base + (y - yi))

        # Content exhausted: every remaining cell of this row is the constant
        # `{attr, bch}` fill — no SGR can arrive (`content[ci]?` stays nil), the
        # single-column `bch` never clusters, and with no selection on the row
        # `highlighted_attr` is `attr` itself. Delegate to `fill_region`, whose
        # per-cell write matches `set_if_changed` exactly (change-skip, overlay
        # drop, dirty-range narrowing). `ci` intentionally stays put: every
        # later read is `content[>= size]` → nil regardless. A `Media::Cells`
        # background or `fill == false` paints nothing for such a row (the
        # per-cell path would `next` every cell).
        if bulk_fill_ok && ci >= content.size && sel_cols.nil?
          if fill && !bg_cells && draw_row
            scr.fill_region(attr, bch, xi, xl, y, y + 1)
          end
          next
        end

        # TODO - make cell exist only if there's something to be drawn there?
        x = xi - 1
        while x < xl - 1
          x += 1
          if x < 0
            # Off the left edge: don't fetch a cell (negative index wraps to the
            # row's right end). Fall through so the content index advances;
            # `target` stays nil, so nothing is painted.
            cell = nil
          else
            cell = line[x]?
            unless cell
              if x >= scr.awidth || xl < iright
                break
              else
                next
              end
            end
          end
          # The cell to actually paint into this iteration, or `nil` when the
          # column/row is off-window. Gates every write below.
          target = draw_row ? cell : nil

          ch = content[ci]? || bch
          ci += 1

          # Handle escape codes.
          while ch == '\e'
            # Recognize the SGR sequence (`\e[[\d;]*m`) by scanning codepoints
            # directly instead of `SGR_REGEX.match`, which allocated a
            # `MatchData`/substring per escape. `ci - 1` is the `\e` just
            # consumed; `ci` should be `[`, then digits/`;`, then `m`.
            if content[ci]? == '[' && (m = sgr_terminator(content, ci + 1))
              # `m` is the index of the trailing 'm'. Parse params straight out of
              # `content` (no substring), then advance past the 'm'.
              attr = scr.attr2code(content, ci - 1, m, attr, default_attr)
              ci = m + 1
              # Ignore foreground changes for selected items (keep default fg,
              # let the rest of the attr change); test hoisted to `keep_selected_fg`.
              if keep_selected_fg
                attr = Attr.pack(Attr.flags(attr), Attr.fg(default_attr), Attr.bg(attr))
              end
              ch = content[ci]? || bch
              ci += 1
            else
              break
            end
          end

          # Handle newlines.
          if ch == '\t'
            # TODO this should be something like ch = bch * style.tab_size, or just style.tab_char,
            # (although not as simple as that.)
            ch = bch
          end
          if ch == '\n'
            # On the first cell, if the last cell of the previous line wasn't a
            # newline, treat this newline as already "counted".
            if (x == xi) && (y != yi) && (content[ci - 2]? != '\n')
              x -= 1
              next
            end
            ch = bch
            # A buffer-image background owns the rest of this line: leave its
            # cells showing the painted image instead of clearing them. The
            # column must still advance to the row end, though — otherwise the
            # loop keeps consuming content and the next logical line's
            # characters continue on this row.
            if bg_cells
              x = xl
            else
              while x < xl
                # Off-window columns (`x < 0`) advance to keep the fill aligned
                # but are never fetched/painted (negative-index wrap).
                fcell = x >= 0 ? line[x]? : nil
                break if x >= 0 && fcell.nil?
                if draw_row && (fc = fcell)
                  paint_attr = highlighted_attr(attr, sel_cols, x - xi)
                  if alpha = style_alpha
                    fc.attr = Colors.blend(paint_attr, fc.attr, alpha: alpha)
                    if content[ci - 1]?
                      fc.char = ch
                    end
                    line.mark_dirty x
                  else
                    fc.set_if_changed(paint_attr, ch)
                  end
                end
                x += 1
              end
            end

            # Newline: row filled to the end, move to the next row.
            next
          end

          # Whether this cell maps to a real content codepoint (vs. the fill
          # char `bch` past the end of content).
          has_content = !content[ci - 1]?.nil?

          # A `Media::Cells` background has painted this box; leave an empty cell
          # showing the image rather than overwriting it. Text cells draw on top.
          next if bg_cells && !has_content

          # Grapheme handling (full_unicode): lay multi-codepoint clusters (emoji
          # ZWJ, flags, base+combining) into one cell + a wide continuation cell;
          # legacy keeps one codepoint per cell. `needs_cluster?` is a fast path
          # ruling out the lone-codepoint common case (no alloc); the allocating
          # `extend_grapheme` runs only for a real cluster.
          grapheme = ""
          cell_width = 1
          is_cluster = false
          if fu && has_content
            if needs_cluster? ch, content[ci]?
              # Costly path — a real multi-codepoint cluster. The `String` alloc
              # is unavoidable (no single-`Char` form; stored in the row's
              # `@graphemes` overlay) but rare, so bounded by cluster cells on
              # window, not total cell count.
              grapheme, ci = extend_grapheme(content, ci, ch)
              cell_width = ::Crysterm::Unicode.width grapheme
              is_cluster = true
              if cell_width == 0
                # Zero-width cluster (e.g. a leading combining mark): merge into
                # the previous cell rather than consuming one. Build the merged
                # cluster in a single allocation: `Cell#grapheme` materializes a
                # fresh `String` (overlay clone or `char.to_s`) and `+` then
                # allocates a second — read the overlay directly and, on the
                # common no-overlay cell, interpolate the base char + mark once (D4).
                if draw_row && x > xi && x - 1 >= 0 && (prev = line[x - 1]?)
                  merged =
                    if ov = prev.grapheme_overlay
                      ov + grapheme
                    else
                      base = prev.char
                      # A continuation cell's `grapheme` is "" (see `Cell#grapheme`),
                      # so preserve that: merge onto nothing.
                      base == Window::Cell::CONTINUATION ? grapheme : "#{base}#{grapheme}"
                    end
                  prev.grapheme = merged
                  line.mark_dirty(x - 1)
                end
                x -= 1
                next
              end
            else
              # Lone codepoint: width straight from the `Char`.
              cell_width = ::Crysterm::Unicode.width ch
            end
          end

          unless fill
            next
          end

          # A wide (2-column) glyph whose continuation cell cannot be claimed —
          # because it falls outside the content region (`x + 1 >= xl`) OR simply
          # does not exist in the screen row (`line[x + 1]?.nil?`, true whenever
          # `x + 1 >= awidth`, i.e. the last screen column even when `xl > awidth`
          # under `Overflow::Ignore`) — cannot be shown: half a wide glyph
          # desyncs cell-index from terminal column. `draw` (window_drawing)
          # claims the continuation cell purely from the lead cell's width, with
          # no knowledge of `xl`, so it would over-claim the neighboring column
          # (e.g. the border) and skip emitting it. Blank the lead cell to a
          # space instead (blessed's end-of-line safeguard), preserving the
          # invariant "a width-2 cell is always followed by an in-region
          # continuation" so `draw` never over-claims. This condition is the exact
          # complement of the continuation-claim block below (`(x + 1 < xl) &&
          # line[x + 1]?`), keeping the two in lockstep.
          if fu && cell_width == 2 && (x + 1 >= xl || line[x + 1]?.nil?)
            ch = ' '
            grapheme = ""
            is_cluster = false
            cell_width = 1
          end

          if t = target
            paint_attr = highlighted_attr(attr, sel_cols, x - xi)
            if alpha = style_alpha
              t.attr = Colors.blend(paint_attr, t.attr, alpha: alpha)
              if has_content
                is_cluster ? (t.grapheme = grapheme) : (t.char = ch)
              end
              line.mark_dirty x
            elsif is_cluster
              if t.attr != paint_attr || !t.grapheme_eq?(grapheme)
                t.attr = paint_attr
                t.grapheme = grapheme
                line.mark_dirty x
              end
            else
              t.set_if_changed(paint_attr, ch)
            end
          end

          # Wide cell (2-column cluster or wide codepoint like CJK): claim the
          # next cell as its continuation so 1 cell == 1 terminal column. The
          # claim happens even off-window to stay in step; only the write is gated.
          if fu && cell_width == 2 && (x + 1 < xl) && (nxt = line[x + 1]?)
            if draw_row && x + 1 >= 0
              if x >= 0
                # Lead cell was actually painted; claim the next cell as its
                # continuation so 1 cell == 1 terminal column.
                nxt.attr = highlighted_attr(attr, sel_cols, x + 1 - xi)
                nxt.continuation!
              else
                # Lead cell fell at x == -1 (clipped by the left screen edge) and
                # was never painted. Marking column 0 as a continuation with no
                # lead anywhere would leave column 0 never repainted and shift the
                # whole row left (see BUGS-F1 findings 10/11). Write a plain blank
                # into column 0 instead, mirroring the end-of-line blanking above.
                nxt.set_if_changed(highlighted_attr(attr, sel_cols, x + 1 - xi), ' ')
              end
              line.mark_dirty(x + 1)
            end
            x += 1
          end
        end
      end

      # Scrollbar: a real `Widget::ScrollBar` child (lazy, fixed at the right
      # edge), styleable/interactive rather than an inline glyph. See
      # `#update_scrollbar_widget`; renders below via `render_children`.
      update_scrollbar_widget if may_scroll

      style.border.try do |border|
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl, -1
      end

      p = padding
      xi, xl, yi, yl = p.adjust xi, xl, yi, yl, -1

      # Add back the row(s) reserved for the horizontal scroll bar (subtracted
      # above): the border must draw at the true bottom edge, not the bar row.
      # Reuses `hsr`.
      yl += hsr

      # Draw the border.
      style.border.try do |border|
        # A border with all sides 0 is "no border": nothing to draw.
        next unless border.any?

        # An explicitly transparent border background (`bg: "transparent"` → -1,
        # distinct from an unset `nil`) shows whatever is already in the buffer
        # behind the border — e.g. a backdrop widget beneath — instead of painting
        # the terminal default over it. Each border cell then keeps its existing
        # bg and only the glyph + fg are drawn over it (see below).
        border_bg_transparent = border.bg == -1

        # Per-side attributes so `border-top-color` etc. can differ, each falling
        # back to the whole-border color. Border bg falls back to the widget's
        # own bg (not the terminal default), so a themed frame sits flush with
        # its interior.
        border_bg = border.bg || style.bg
        top_attr = sattr border, border.top_fg, border_bg
        bottom_attr = sattr border, border.bottom_fg, border_bg
        left_attr = sattr border, border.left_fg, border_bg
        right_attr = sattr border, border.right_fg, border_bg

        # Resolved once here instead of re-dispatching per cell inside
        # `border_char`, with any per-position char overrides (CSS
        # `border-chars`/`border-top-left-char` …) merged over the family.
        glyphs = border.line_glyphs_with_overrides(glyph_tier)

        # Interior (content) rectangle: the outer box `(xi..xl, yi..yl)` inset by
        # each side's thickness. A side thicker than one cell fills its whole
        # reserved band (nested/repeated lines), not just the outermost row/col —
        # every cell of the outer box outside this interior is a border cell.
        in_yi = yi + border.top
        in_yl = yl - border.bottom
        in_xi = xi + border.left
        in_xl = xl - border.right

        (yi...yl).each do |y|
          next if y < 0 # off the top edge (a negative index would wrap)
          line = lines[y]?
          next unless line

          in_top = y < in_yi  # within the top band
          in_bot = y >= in_yl # within the bottom band

          # Skip a band row that's clipped offscreen — it isn't present here.
          next if in_top && coords.no_top?
          next if in_bot && coords.no_bottom?

          # Only border cells are visited: a middle (non-band) row jumps from
          # the end of the left band straight to the right band instead of
          # walking (and skipping) every interior cell — O(perimeter) instead of
          # O(area) for the whole loop. Band rows still walk full width.
          x = xi < 0 ? 0 : xi # off the left edge (a negative index would wrap)
          while x < xl
            # Interior (content) region on a middle row: skip it in one jump.
            if !in_top && !in_bot && x >= in_xi && x < in_xl
              x = in_xl
              next
            end

            in_left = x < in_xi   # within the left band
            in_right = x >= in_xl # within the right band

            if (in_left && coords.no_left?) || (in_right && coords.no_right?)
              x += 1
              next
            end

            cell = line[x]?
            unless cell
              x += 1
              next
            end

            ch = border_char border, glyphs, in_top, in_bot, in_left, in_right
            # Horizontal (top/bottom) cells — including corners — take the
            # top/bottom color; a purely vertical cell takes left/right.
            battr = if in_top || in_bot
                      in_top ? top_attr : bottom_attr
                    else
                      in_left ? left_attr : right_attr
                    end

            # Transparent bg: substitute the cell's current background so the
            # backdrop shows through, keeping only the border's flags + fg.
            battr = Attr.pack(Attr.flags(battr), Attr.fg(battr), Attr.bg(cell.attr)) if border_bg_transparent

            cell.set_if_changed(battr, ch)
            x += 1
          end
        end
      end

      # Shadow: each side blends a band of cells toward black via
      # `Window#blend_region`, differing only in bounds.
      if (s = style.shadow) && s.any?
        # Half-block (thin) shadow: each band is split into the straight run
        # alongside the box and the corner caps beyond its edges, so the cell
        # where two bands meet gets its own diagonal glyph rather than the
        # abutting side's (see `Shadow`'s glyph resolution). Corner ownership
        # follows the same band-partition the plain path relies on, so no cell
        # is painted twice. The plain (no-glyphs) path instead does a single
        # blend per band, clamping the band's origin into the screen.
        if s.left?
          i = (yi - s.top) + (s.bottom? && !s.top? && !s.right? ? s.bottom : 0)
          l = s.bottom? ? yl + s.bottom : yl - (s.top? && !s.bottom? ? s.top : 0)
          if s.glyphs?
            blend_shadow_v scr, s, xi - s.left, xi, i, l, yi, yl, s.left_char, s.top_left_char, s.bottom_left_char
          else
            scr.blend_region s.alpha, xi - s.left, xi, Math.max(i, 0), l
          end
        end

        if s.top?
          l = s.right? ? xl + s.right : (s.left? ? xl - s.left : xl)
          if s.glyphs?
            blend_shadow_h scr, s, xi, l, yi - s.top, yi, xi, xl, s.top_char, s.top_left_char, s.top_right_char
          else
            scr.blend_region s.alpha, Math.max(xi, 0), l, yi - s.top, yi
          end
        end

        if s.right?
          i = (s.top? || s.left?) ? yi : yi + s.bottom
          l = s.bottom? ? yl + s.bottom : yl
          if s.glyphs?
            blend_shadow_v scr, s, xl, xl + s.right, i, l, yi, yl, s.right_char, s.top_right_char, s.bottom_right_char
          else
            scr.blend_region s.alpha, xl, xl + s.right, Math.max(i, 0), l
          end
        end

        if s.bottom?
          i = s.right? ? xi + (s.left? ? 0 : s.right) : xi
          l = xl - (s.left? && !s.top? && !s.right? ? s.left : 0)
          if s.glyphs?
            blend_shadow_h scr, s, i, l, yl, yl + s.bottom, xi, xl, s.bottom_char, s.bottom_left_char, s.bottom_right_char
          else
            scr.blend_region s.alpha, Math.max(i, 0), l, yl, yl + s.bottom
          end
        end
      end

      # Tint: colored overlay across the whole box toward `style.tint`. Applied
      # before children so each widget tints only its own cells; animatable via
      # `Widget#tint_to`.
      if t = style.tint?
        color, ta = t
        scr.tint_region ta, color, xi, xl, yi, yl
      end

      if with_children
        # The installed layout engine positions/renders children; with none, the
        # shared `Layout::Manual` renders each at its own coordinates.
        (@layout || Crysterm::Layout::Manual::DEFAULT).render_children self
      end

      emit Crysterm::Event::Rendered # , coords

      coords
    end

    # Paints a vertical (left/right) thin-shadow band in columns *cx0*...*cx1*,
    # rows *i*...*l*, split at the box's own row span *yi*...*yl*: the middle run
    # uses *run*, and the caps beyond the box's top/bottom edges — where this band
    # meets a horizontal one — use *top_cap*/*bot_cap*. Sub-ranges that collapse
    # to nothing (no cap on that side) draw no cells, so each corner is painted by
    # exactly one band.
    private def blend_shadow_v(scr, s, cx0, cx1, i, l, yi, yl, run, top_cap, bot_cap)
      scr.blend_region s.alpha, cx0, cx1, i, Math.min(l, yi), glyph: top_cap
      scr.blend_region s.alpha, cx0, cx1, Math.max(i, yi), Math.min(l, yl), glyph: run
      scr.blend_region s.alpha, cx0, cx1, Math.max(i, yl), l, glyph: bot_cap
    end

    # :ditto: for a horizontal (top/bottom) band in rows *ry0*...*ry1*, columns
    # *i*...*l*, split at the box's own column span *xi*...*xl* (run + left/right
    # corner caps).
    private def blend_shadow_h(scr, s, i, l, ry0, ry1, xi, xl, run, left_cap, right_cap)
      scr.blend_region s.alpha, i, Math.min(l, xi), ry0, ry1, glyph: left_cap
      scr.blend_region s.alpha, Math.max(i, xi), Math.min(l, xl), ry0, ry1, glyph: run
      scr.blend_region s.alpha, Math.max(i, xl), l, ry0, ry1, glyph: right_cap
    end

    # Registers on the window the rows where this widget emits horizontal
    # line-drawing chars, so the docking pass (`Window#_dock`) joins them with
    # crossing chars from neighbors (see `Crysterm::Docking`). Only rows with
    # horizontal segments need registering (verticals dock when a horizontal
    # stop crosses them). Base registers top/bottom rows of a line-type border;
    # widgets drawing lines otherwise (e.g. `Widget::Line`) override this.
    def register_dock_stops(coords)
      style.border.try do |border|
        if border.any? && border.type.line?
          # A widget rendering into a compositing plane registers on the *plane*
          # stops so overlay borders join each other but not the base content
          # beneath; a base-layer widget uses the window stops.
          #
          # Gate is the window's `compositing_layers?`, NOT this widget's
          # `@compositing` (set only on the layer root) — else a bordered
          # descendant would register on the BASE stops and dock to base
          # content, producing stray junctions.
          scr = window
          stops = scr.compositing_layers? ? scr._plane_dock_stops : scr._dock_stops
          stops[coords.yi] = true
          stops[coords.yl - 1] = true
        end
      end
    end

    # Re-joins the line-drawing characters on the given window *rows* into
    # seamless junctions (`├ ┤ ┬ ┼` …), reusing the window's `Docking` component
    # on demand for one widget. Lets a widget connect interior line art (e.g. a
    # `Menu`'s separator rules) to its own border. No-op when detached or given
    # no rows.
    #
    # *contrast* defaults to `DockContrast::Ignore` (only the glyph changes,
    # not cell colors) rather than the window's global setting — `Blend` would
    # diffuse the junction's color along the whole run, muddying e.g. a
    # separator's divider color.
    protected def dock_rows(rows : Enumerable(Int32), contrast : DockContrast = DockContrast::Ignore) : Nil
      scr = window? || return
      # Reuse a per-widget Hash instead of allocating one per frame (D1). Single
      # fiber renders, so the scratch set is never live across calls.
      stops = (@_dock_rows_stops ||= {} of Int32 => Bool)
      stops.clear
      rows.each { |y| stops[y] = true }
      return if stops.empty?
      Docking.dock scr.lines, stops, scr.awidth, contrast, scr.glyph_tier.ascii?
    end

    @[AlwaysInline]
    # Picks the glyph for one border cell, classified by which band(s) it falls
    # in: `in_top`/`in_bot` mark a horizontal (top/bottom) band, `in_left`/
    # `in_right` a vertical (left/right) band. A cell in both a horizontal and a
    # vertical band is a corner/join cell. The classification is thickness-aware,
    # so a side wider than one cell fills its whole band with the run glyph and
    # the corner block with the corner glyph. A side with 0 thickness never sets
    # its flag (`in_top` is `y < yi + 0`, always false at the edge), so a
    # corner degrades to the crossing run glyph.
    def border_char(border, g, in_top, in_bot, in_left, in_right)
      h_band = in_top || in_bot
      v_band = in_left || in_right

      if border.type.line_family?
        # Per-type glyph set (solid/dashed/dotted/double), resolved once by the
        # caller.
        if h_band && v_band
          if in_top
            in_left ? g[:tl] : g[:tr]
          else
            in_left ? g[:bl] : g[:br]
          end
        elsif h_band
          g[:h]
        else
          g[:v]
        end
      else # Bg
        # Distinct glyphs for horizontal sides, vertical sides and the four
        # corners, each defaulting through its group to `fill_char` (see
        # `Border#horizontal_char`/`#vertical_char`/`#top_left_char` …).
        if h_band && v_band
          if in_top
            in_left ? border.top_left_char : border.top_right_char
          else
            in_left ? border.bottom_left_char : border.bottom_right_char
          end
        elsif h_band
          border.horizontal_char
        else
          border.vertical_char
        end
      end
    end

    # Returns the codepoint index of the `m` terminating an SGR sequence whose
    # parameter run starts at `i` (first codepoint after `\e[`), or `nil` if the
    # run is not `[\d;]* m`. Lets `_render` recognize SGR sequences without
    # allocating a `Regex::MatchData`/substring per escape.
    private def sgr_terminator(content : StringIndex, i : Int32) : Int32?
      while ch = content[i]?
        if ch == 'm'
          return i
        elsif ch == ';' || (ch >= '0' && ch <= '9')
          i += 1
        else
          return nil
        end
      end
      nil
    end

    def render(with_children = true)
      _render with_children
    end

    # Runs the base `_render`, insets the resulting coordinates by this widget's
    # border, and yields the interior rectangle `(xi, xl, yi, yl)` for a widget
    # that paints its own interior on top of the standard render (e.g.
    # `ProgressBar`, `Gradient`). Returns the render's `LPos` (or `nil` when
    # nothing was rendered). Use `next` inside the block to bail out early while
    # still returning the coords.
    def with_inner_coords(& : (Int32, Int32, Int32, Int32) -> _) : LPos?
      ret = _render
      return unless ret
      # Inset by the border to get the interior rectangle, but do NOT mutate
      # `ret` — it's this widget's cached `@lpos`. `Border#adjust(pos)` shrinks
      # in place, so mutating it via `style.border.try &.adjust(ret)` would
      # permanently collapse `@lpos` to the interior, under-reporting mouse
      # hit-testing, damage-tracking bounds, and `clear_last_rendered_position`
      # until the next frame. Use the allocation-free by-value overload instead,
      # leaving `@lpos`/`ret` describing the full widget rect.
      xi, xl, yi, yl = ret.xi, ret.xl, ret.yi, ret.yl
      if border = style.border
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl
      end
      yield xi, xl, yi, yl
      ret
    end

    # Like `with_inner_coords`, but insets the rendered rectangle by the border
    # AND the padding — the interior *content* region, matching the two-step
    # inset `_render` itself applies (border first, then padding) before laying
    # out content. Yields `(xi, xl, yi, yl)` for a widget that paints its own
    # content straight into the cell buffer on top of the standard render (e.g.
    # `Effect::Direct`). Returns the render's `LPos` (or `nil` when nothing was
    # rendered). `with_children` is forwarded to `_render` so an interior-painting
    # widget can still opt out of rendering its children.
    def with_content_coords(with_children = true, & : (Int32, Int32, Int32, Int32) -> _) : LPos?
      ret = _render with_children
      return unless ret
      # By-value inset only — never mutate `ret` (it is this widget's cached
      # `@lpos`); see the note in `with_inner_coords`.
      xi, xl, yi, yl = ret.xi, ret.xl, ret.yi, ret.yl
      if border = style.border
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl
      end
      xi, xl, yi, yl = style.padding.adjust xi, xl, yi, yl
      yield xi, xl, yi, yl
      ret
    end

    def self.sattr(style, fg = nil, bg = nil) : Int64
      if fg.nil? && bg.nil?
        fg = style.fg
        bg = style.bg
      end

      # TODO support style.* being Procs ?

      flags =
        (style.visible? ? 0 : Attr::INVISIBLE) |
          (style.reverse? ? Attr::REVERSE : 0) |
          (style.blink? ? Attr::BLINK : 0) |
          (style.underline? ? Attr::UNDERLINE : 0) |
          (style.italic? ? Attr::ITALIC : 0) |
          (style.strike? ? Attr::STRIKE : 0) |
          (style.bold? ? Attr::BOLD : 0)

      # `fg`/`bg` are already native colors (`0xRRGGBB` int, `-1` for terminal
      # default, `nil` for unset). `Attr.pack_color` packs that into a color
      # field; no per-frame string parsing.
      Attr.pack(flags, Attr.pack_color(fg || -1), Attr.pack_color(bg || -1))
    end

    def sattr(style, fg = nil, bg = nil)
      self.class.sattr style, fg, bg
    end

    def last_rendered_position
      @lpos.try do |pos|
        # Return cached value if already computed.
        return pos if pos.aleft

        pos.aleft = pos.xi
        pos.atop = pos.yi
        pos.aright = window.awidth - pos.xl
        pos.abottom = window.aheight - pos.yl
        pos.awidth = pos.xl - pos.xi
        pos.aheight = pos.yl - pos.yi

        # Carry these over too:
        pos.ileft = ileft
        pos.itop = itop
        pos.iright = iright
        pos.ibottom = ibottom

        return pos
      end

      raise "Shouldn't happen"
      # Just to satisfy the return type. If this can realistically happen,
      # return something like `LPos.new` instead (carrying over the i* values).
    end

    # Clears area/position of widget's last render
    def clear_last_rendered_position(get = false, override = false)
      return unless window?
      # Reuse the cached `@lpos` from the previous `_render` instead of
      # recomputing geometry from scratch — it's still correct even after the
      # caller moved the widget, since `@lpos` holds where it actually painted.
      # Falls back to `_get_coords` only when never rendered. Same
      # `@lpos || _get_coords` idiom as `widget_scrolling.cr`.
      lpos = @lpos || _get_coords(get)
      return unless lpos
      window.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, override)
    end
  end
end
