module Crysterm
  class Widget
    # module Rendering
    include Crystallabs::Helpers::Alias_Methods

    # Per-widget override of the overflow action; `nil` = inherit the window
    # default. Read through `#overflow`.
    @overflow : Overflow? = nil

    # Reused stops set for `#dock_rows`, cleared per call. Lazily allocated on
    # first use (many widgets never dock rows).
    @_dock_rows_stops : Hash(Int32, Bool)? = nil

    # Action when this widget overflows its parent's rectangle: the per-widget
    # override if set, else the window default (`Overflow::Ignore` if window-less).
    def overflow : Overflow
      @overflow || window?.try(&.overflow) || Overflow::Ignore
    end

    # The raw per-widget override (`nil` = inheriting the window default).
    # Unlike `#overflow`, does not resolve the inherited value.
    def own_overflow : Overflow?
      @overflow
    end

    def overflow=(value : Overflow?)
      @overflow = value
    end

    def overflow=(value : ::Crystallabs::Helpers::Enums::Shorthands)
      @overflow = ::Crystallabs::Helpers::Enums.from(Overflow, value)
    end

    # Layout engine arranging this widget's children, or `nil` for manual
    # placement, in which case `#_render` uses `Layout::Manual`. Mirrors Qt's
    # null `QWidget::layout()`.
    @layout : Crysterm::Layout? = nil

    # :ditto:
    def layout : Crysterm::Layout?
      @layout
    end

    # :ditto: — change-guarded. Installs the layout's `#container` back-pointer
    # (and clears the outgoing one), then schedules a repaint so the newly
    # installed engine arranges the children.
    def layout=(value : Crysterm::Layout?) : Crysterm::Layout?
      return value if value == @layout
      @layout.try(&.container=(nil))
      @layout = value
      value.try(&.container=(self))
      mark_dirty
      value
    end

    # Optional per-child hint read by this widget's *parent's* layout engine
    # (Border region, Grid cell+span, flex stretch factor).
    @layout_hint : Crysterm::Layout::Hint? = nil

    # :ditto:
    def layout_hint : Crysterm::Layout::Hint?
      @layout_hint
    end

    # :ditto: — change-guarded; a real change repaints (so the parent's engine
    # re-places this child).
    def layout_hint=(value : Crysterm::Layout::Hint?) : Crysterm::Layout::Hint?
      return value if value == @layout_hint
      @layout_hint = value
      mark_dirty
      value
    end

    # Whether this widget keeps its layout slot while hidden (Qt's
    # `QSizePolicy#retainSizeWhenHidden`). Off by default, so hiding a child of
    # a packing engine (`Layout::VBox`, `HBox`, `Border`) gives its space back
    # to its siblings; turn it on to hide a widget *in place*.
    #
    # Slot-addressed engines (`Layout::Stack` pages, `Layout::Grid` cells)
    # ignore this: their children are identified by position, so a hidden one
    # must keep its index.
    property? retain_size_when_hidden : Bool = false

    # Docks this widget to a `Layout::Border` region, wrapping *region* in a
    # `Layout::Border::Hint`:
    #
    # ```
    # Widget::Box.new parent: frame, height: 1, layout_hint: :top
    # ```
    #
    # Qt spells the same thing `addWidget(w, BorderLayout::North)`. Takes the
    # same shorthand forms as `#align`/`#overflow` (`:top`, `"top"`). The
    # `Layout::Hint` overload serves engines with richer hints (Grid's
    # cell+span, flex grow).
    def layout_hint=(region : Crysterm::Layout::Border::Region) : Crysterm::Layout::Hint?
      self.layout_hint = Crysterm::Layout::Border::Hint.new region
    end

    # :ditto:
    def layout_hint=(region : ::Crystallabs::Helpers::Enums::Shorthands) : Crysterm::Layout::Hint?
      self.layout_hint = ::Crystallabs::Helpers::Enums.from Crysterm::Layout::Border::Region, region
    end

    # A parent always renders before its children, so a child may reuse the
    # parent's `lpos` rather than recomputing it (which mishandles content
    # shrinkage). Stale if the parent is moved afterwards.

    property items = [] of Widget::Box

    # True only while this widget renders as a layer root into its own `Plane`.
    # Translucency then comes from the plane's opacity, so the render-time
    # self-blend is suppressed.
    property compositing = false

    # Resolves the `Style` a *child* should render with, called on the child's
    # parent. Base returns the child's own style; containers that style children
    # (e.g. `Widget::List` highlighting the selected row) override this.
    def render_style_for(item : Widget) : Style
      item.style
    end

    # Column range (`x - xi` units, half-open) on real (post-wrap) line *rl* to
    # paint with the selection highlight, or `nil` for none. Overridden by
    # widgets that can hold an active selection.
    protected def selection_columns_for_row(rl : Int32) : Range(Int32, Int32)?
      nil
    end

    # *attr* with the selection highlight applied (reverse video) when *col*
    # falls inside *sel_cols*, else *attr* unchanged.
    @[AlwaysInline]
    private def highlighted_attr(attr : Int64, sel_cols : Range(Int32, Int32)?, col : Int32) : Int64
      return attr unless sel_cols && sel_cols.includes?(col)
      Attr.pack(Attr.flags(attr) | Attr::REVERSE, Attr.fg(attr), Attr.bg(attr))
    end

    # Whether a `Layout` suppressed this widget's subtree on the last render —
    # e.g. a non-current `Layout::Stack` page. Distinguishes a *layout-hidden*
    # widget, which must not be a focus/Tab target, from one merely *scrolled
    # out* of a viewport, which stays Tab-reachable; both null `lpos`, so `lpos`
    # alone cannot tell them apart.
    property? layout_suppressed : Bool = false

    # Renders all child elements into the output buffer.
    # ameba:disable Metrics/CyclomaticComplexity
    def _render(with_children = true)
      # Reaching here means this widget is on the active layout branch. Cleared
      # before the early-outs below so a scrolled/clipped-out widget (which
      # still returns here) stays focus-reachable.
      @layout_suppressed = false
      emit Crysterm::Event::PreRender

      # Let the parent dictate this widget's render style (a list highlights its
      # selected row); an ordinary parent just hands back our own style.
      # `own_style` lets `default_attr` below detect when the render style IS our
      # own and reuse the `style_to_attr` from `process_content`.
      own_style = self.style
      style = parent.try(&.render_style_for(self)) || own_style

      # Keep any border label glued to the (possibly CSS-resolved) top inset.
      # Must run before the label child renders.
      sync_label_position

      # `awidth(true)` is an O(1) read of the parent's already-rendered cached
      # `lpos`. Resolve once and pass to both `process_content` and `coords`
      # instead of each walking the ancestor chain separately.
      aw = awidth(true)
      process_content awidth_hint: aw

      # Pass `@lpos` so `coords` updates it in place rather than allocating a
      # fresh `RenderedGeometry` every frame.
      coords = coords(true, into: @lpos, width_hint: aw)
      unless coords
        # No on-screen rect this frame (scrolled/clipped out of a scrollable
        # ancestor's viewport, or the ancestor has no `lpos`): this widget and
        # its descendants paint nowhere, so clear their last-rendered rects, or
        # `Window#widget_at` keeps routing clicks/hovers to the stale subtree
        # rects. Layout-excluded chrome renders out-of-band with its own live
        # `lpos`, so leave it untouched.
        @lpos = nil
        children.each { |c| clear_subtree_lpos c unless c.layout_excluded? }
        return
      end

      if coords.xl - coords.xi <= 0
        coords.xl = Math.max(coords.xl, coords.xi)
        # Our own zero-width rect is un-hittable, but descendants would keep the
        # previous frame's rects (see above).
        children.each { |c| clear_subtree_lpos c unless c.layout_excluded? }
        return
      end

      if coords.yl - coords.yi <= 0
        coords.yl = Math.max(coords.yl, coords.yi)
        children.each { |c| clear_subtree_lpos c unless c.layout_excluded? }
        return
      end

      # `window` walks the parent chain on every call; bind it once. The style
      # values below are constant for the render, so hoist them out of the
      # per-cell loops.
      scr = window
      # No-op unless an `animation` is declared.
      ensure_css_animation

      lines = scr.lines
      fu = scr.full_unicode_effective?
      # A layer root's opacity is applied as its plane's opacity at composite time,
      # so suppress the render-time self-blend while painting into the plane.
      style_opacity = @compositing ? nil : style.opacity?
      padding = style.padding
      fill = style.fill?
      xi = coords.xi
      xl = coords.xl
      yi = coords.yi
      yl = coords.yl
      # `#pcontent` materializes the printable string if a deferred append left it
      # stale, caching into `@_pcontent`. Once per frame, not per appended line.
      pcontent = self.pcontent
      # Reuse the cached codepoint index unless `@_pcontent` was reparsed into a
      # fresh `String` (identity check).
      content = @_content_index
      unless content && content.built_from?(pcontent)
        content = StringIndex.new pcontent
        @_content_index = content
      end
      ci = @_clines.ci[coords.base]? || 0 # XXX Is it ok that array lookup can be nil? and defaulting to 0?
      bch = style.fill_char

      if coords.base >= @_clines.ci.size
        ci = content.size
      end

      @lpos = coords

      register_dock_stops coords

      # `process_content` already cached `style_to_attr(self.style)` in `@_parse_attr_default`;
      # reuse it unless a parent substituted a style. `|| style_to_attr(style)` is a
      # defensive fallback.
      default_attr = (style.same?(own_style) ? @_parse_attr_default : nil) || style_to_attr(style)
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
      # never paints under it. `may_scroll` also stays true for a widget that
      # *was* scrollable, so its bar gets hidden when scrolling is turned off.
      # Must be computed before the pre-fill, which needs `hsr` to size the
      # bottom band.
      may_scroll = scrollable? || !@scrollbar_widget.nil? || !@horizontal_scrollbar_widget.nil?
      hsr = may_scroll ? hscrollbar_rows : 0

      # Padding/valign make the content loop skip some cells/lines, so fill
      # those ahead of time. On the common opaque-fill path only the padding
      # bands and the scrollbar-reserved rows need pre-filling (the loop paints
      # the valign gap itself — a negative `ci` indexes to nil, i.e. the `bch`
      # fill). A background-image widget keeps the whole-box fill; a
      # `fill: false` widget must not be filled at all.
      if padding.any? || !@align.top?
        if (opacity = style_opacity) && fill
          # Pre-blend only the bands the content loop won't reach: it blends the
          # content region itself, and blending twice makes a padded translucent
          # widget's interior more opaque than its padding. A background-image
          # widget's content loop leaves empty cells untouched, so there the
          # whole-box blend must stay.
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
              cell.attr = Colors.blend(attr, cell.attr, alpha: opacity)
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
          # A background-image widget (the image paints over this base fill) or
          # a `fill: false` widget. The `fill` gate keeps the latter transparent:
          # without it, padding or vertical alignment would silently turn its
          # background opaque.
          scr.fill_region(default_attr, bch, xi, xl, yi, yl) if fill
        end
      end

      # Background image (CSS `background-image`): paint the internal `Media`
      # layer before the content loop so text draws on top. `bg_cells` tells the
      # content loop to leave empty cells showing the image when a
      # `Media::Cells` layer paints the buffer.
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
        parent2.item_view? && parent2.interactive? && parent2.item_selected?(self) # XXX && parent2.invert_selected
      end || false

      # Whether a row whose content is exhausted may be painted as one
      # `fill_region` sweep instead of walking the full per-cell machinery (the
      # very common "large box, little content" case). Everything except the
      # alpha blend writes a constant `{attr, bch}` there, so only the blend
      # needs the per-cell path.
      bulk_fill_ok = style_opacity.nil?

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
        # hazard per-cell for `x < 0`).
        draw_row = y >= 0

        # `y - yi` assumes top alignment.
        sel_cols = selection_columns_for_row(coords.base + (y - yi))

        # Content exhausted: every remaining cell of this row is the constant
        # `{attr, bch}` fill — no SGR can arrive, the single-column `bch` never
        # clusters, and with no selection `highlighted_attr` is `attr` itself.
        # `ci` intentionally stays put: every later read is `content[>= size]` →
        # nil regardless.
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
            # directly rather than by regex, which allocates per escape. `ci - 1`
            # is the `\e` just consumed; `ci` should be `[`, then digits/`;`,
            # then `m`.
            if content[ci]? == '[' && (m = sgr_terminator(content, ci + 1))
              # `m` is the index of the trailing 'm'. Parse params straight out of
              # `content` (no substring), then advance past the 'm'.
              attr = scr.sgr_to_attr(content, ci - 1, m, attr, default_attr)
              ci = m + 1
              # Selected items keep the default fg; the rest of the attr changes.
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
            # A buffer-image background owns the rest of this line, and a
            # `fill: false` widget draws no background: paint nothing across the
            # row tail. The column must still advance to the row end, or the loop
            # keeps consuming content and the next logical line continues on this
            # row.
            if bg_cells || !fill
              x = xl
            else
              while x < xl
                # Off-window columns (`x < 0`) advance to keep the fill aligned
                # but are never fetched/painted (negative-index wrap).
                fcell = x >= 0 ? line[x]? : nil
                break if x >= 0 && fcell.nil?
                if draw_row && (fc = fcell)
                  paint_attr = highlighted_attr(attr, sel_cols, x - xi)
                  if opacity = style_opacity
                    fc.attr = Colors.blend(paint_attr, fc.attr, alpha: opacity)
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
          # legacy keeps one codepoint per cell. `needs_cluster?` is an
          # alloc-free fast path for the lone-codepoint common case.
          grapheme = ""
          cell_width = 1
          is_cluster = false
          if fu && has_content
            if needs_cluster? ch, content[ci]?
              # Costly path — a real multi-codepoint cluster, whose `String`
              # alloc is unavoidable but bounded by cluster cells on window.
              grapheme, ci = extend_grapheme(content, ci, ch)
              cell_width = ::Crysterm::Unicode.width grapheme
              is_cluster = true
              if cell_width == 0
                # Zero-width cluster (e.g. a leading combining mark): merge into
                # the previous cell rather than consuming one. The overlay is
                # read directly, and the base char interpolated, to build the
                # merged cluster in a single allocation.
                if draw_row && x > xi && x - 1 >= 0 && (prev = line[x - 1]?)
                  merged =
                    if ov = prev.grapheme_overlay
                      ov + grapheme
                    else
                      base = prev.char
                      # A continuation cell's grapheme is "": merge onto nothing.
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
          # outside the content region, or absent from the screen row — is blanked
          # to a space (blessed's end-of-line safeguard), upholding the invariant
          # "a width-2 cell is always followed by an in-region continuation".
          # Drawing claims the continuation from the lead cell's width alone,
          # knowing nothing of `xl`, so without this it over-claims the neighboring
          # column. Must stay the exact complement of the continuation-claim block
          # below.
          if fu && cell_width == 2 && (x + 1 >= xl || line[x + 1]?.nil?)
            ch = ' '
            grapheme = ""
            is_cluster = false
            cell_width = 1
          end

          if t = target
            paint_attr = highlighted_attr(attr, sel_cols, x - xi)
            if opacity = style_opacity
              t.attr = Colors.blend(paint_attr, t.attr, alpha: opacity)
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
                nxt.attr = highlighted_attr(attr, sel_cols, x + 1 - xi)
                nxt.continuation!
              else
                # Lead cell fell at x == -1 (clipped by the left screen edge) and
                # was never painted. Marking column 0 as a continuation with no
                # lead anywhere would leave it never repainted and shift the whole
                # row left. Write a plain blank instead, mirroring the
                # end-of-line blanking above.
                nxt.set_if_changed(highlighted_attr(attr, sel_cols, x + 1 - xi), ' ')
              end
              line.mark_dirty(x + 1)
            end
            x += 1
          end
        end
      end

      # Scrollbar: a real `Widget::ScrollBar` child (lazy, fixed at the right
      # edge), styleable/interactive rather than an inline glyph.
      update_scrollbar_widget if may_scroll

      style.border.try do |border|
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl, -1
      end

      p = padding
      xi, xl, yi, yl = p.adjust xi, xl, yi, yl, -1

      # Add back the row(s) reserved for the horizontal scroll bar (subtracted
      # above): the border must draw at the true bottom edge, not the bar row.
      yl += hsr

      # Draw the border.
      style.border.try do |border|
        # A border with all sides 0 is "no border": nothing to draw.
        next unless border.any?

        # An explicitly transparent border background (`bg: "transparent"` → -1,
        # distinct from an unset `nil`) shows whatever is already in the buffer
        # behind the border; each border cell keeps its existing bg and only the
        # glyph + fg are drawn over it.
        border_bg_transparent = border.bg == -1

        # Per-side attributes so `border-top-color` etc. can differ, each falling
        # back to the whole-border color. Border bg falls back to the widget's
        # own bg (not the terminal default), so a themed frame sits flush with
        # its interior.
        border_bg = border.bg || style.bg
        # All four sides share `border` as the style object, so the SGR flag word
        # is identical across them — computed once, with only the fg per side.
        border_flags = self.class.style_to_attr_flags(border)
        top_attr = self.class.pack_attr border_flags, border, border.top_fg, border_bg
        bottom_attr = self.class.pack_attr border_flags, border, border.bottom_fg, border_bg
        left_attr = self.class.pack_attr border_flags, border, border.left_fg, border_bg
        right_attr = self.class.pack_attr border_flags, border, border.right_fg, border_bg

        # The glyph family with any per-position char overrides (CSS
        # `border-chars`/`border-top-left-char` …) merged over it, resolved once
        # rather than per cell.
        glyphs = border.line_glyphs_with_overrides(glyph_tier)

        # Interior (content) rectangle: the outer box `(xi..xl, yi..yl)` inset by
        # each side's thickness. Every cell of the outer box outside it is a
        # border cell, so a side thicker than one cell fills its whole band.
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

          # Only border cells are visited: a middle (non-band) row jumps from the
          # end of the left band straight to the right band, making the loop
          # O(perimeter) rather than O(area). Band rows still walk full width.
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

      # Shadow: each side blends a band of cells toward black, differing only in
      # bounds.
      if (s = style.shadow) && s.any?
        # Half-block (thin) shadow: each band splits into the straight run
        # alongside the box and the corner caps beyond its edges, so the cell
        # where two bands meet gets its own diagonal glyph. Corner ownership
        # follows the band partition, so no cell is painted twice. The plain
        # (no-glyphs) path does a single blend per band instead.
        if s.left?
          i = (yi - s.top) + (s.bottom? && !s.top? && !s.right? ? s.bottom : 0)
          l = s.bottom? ? yl + s.bottom : yl - (s.top? && !s.bottom? ? s.top : 0)
          if s.glyphs?
            blend_shadow_v scr, s, xi - s.left, xi, i, l, yi, yl, s.left_char, s.top_left_char, s.bottom_left_char
          else
            scr.blend_region s.opacity, xi - s.left, xi, Math.max(i, 0), l
          end
        end

        if s.top?
          l = s.right? ? xl + s.right : (s.left? ? xl - s.left : xl)
          if s.glyphs?
            blend_shadow_h scr, s, xi, l, yi - s.top, yi, xi, xl, s.top_char, s.top_left_char, s.top_right_char
          else
            scr.blend_region s.opacity, Math.max(xi, 0), l, yi - s.top, yi
          end
        end

        if s.right?
          i = (s.top? || s.left?) ? yi : yi + s.bottom
          l = s.bottom? ? yl + s.bottom : yl
          if s.glyphs?
            blend_shadow_v scr, s, xl, xl + s.right, i, l, yi, yl, s.right_char, s.top_right_char, s.bottom_right_char
          else
            scr.blend_region s.opacity, xl, xl + s.right, Math.max(i, 0), l
          end
        end

        if s.bottom?
          i = s.right? ? xi + (s.left? ? 0 : s.right) : xi
          l = xl - (s.left? && !s.top? && !s.right? ? s.left : 0)
          if s.glyphs?
            blend_shadow_h scr, s, i, l, yl, yl + s.bottom, xi, xl, s.bottom_char, s.bottom_left_char, s.bottom_right_char
          else
            scr.blend_region s.opacity, Math.max(i, 0), l, yl, yl + s.bottom
          end
        end
      end

      # Tint: colored overlay across the whole box toward `style.tint`. Must be
      # applied before children, so each widget tints only its own cells.
      if t = style.tint?
        color, ta = t
        scr.tint_region ta, color, xi, xl, yi, yl
      end

      if with_children
        # The installed layout engine positions/renders children; with none, the
        # shared `Layout::Manual` renders each at its own coordinates.
        if l = @layout
          # Back-pointer, set here too so engines installed by direct `@layout =`
          # (bypassing `#layout=`) still resolve their container. Never set on the
          # shared `Manual::DEFAULT`, which serves every layout-less widget.
          l.container = self
          l.render_children self
        else
          Crysterm::Layout::Manual::DEFAULT.render_children self
        end
      end

      emit Crysterm::Event::Rendered

      coords
    end

    # Paints a vertical (left/right) thin-shadow band in columns *cx0*...*cx1*,
    # rows *i*...*l*, split at the box's own row span *yi*...*yl*: the middle run
    # uses *run*, and the caps beyond the box's top/bottom edges — where this band
    # meets a horizontal one — use *top_cap*/*bot_cap*. Sub-ranges that collapse
    # to nothing (no cap on that side) draw no cells, so each corner is painted by
    # exactly one band.
    private def blend_shadow_v(scr, s, cx0, cx1, i, l, yi, yl, run, top_cap, bot_cap)
      scr.blend_region s.opacity, cx0, cx1, i, Math.min(l, yi), glyph: top_cap
      scr.blend_region s.opacity, cx0, cx1, Math.max(i, yi), Math.min(l, yl), glyph: run
      scr.blend_region s.opacity, cx0, cx1, Math.max(i, yl), l, glyph: bot_cap
    end

    # :ditto: for a horizontal (top/bottom) band in rows *ry0*...*ry1*, columns
    # *i*...*l*, split at the box's own column span *xi*...*xl* (run + left/right
    # corner caps).
    private def blend_shadow_h(scr, s, i, l, ry0, ry1, xi, xl, run, left_cap, right_cap)
      scr.blend_region s.opacity, i, Math.min(l, xi), ry0, ry1, glyph: left_cap
      scr.blend_region s.opacity, Math.max(i, xi), Math.min(l, xl), ry0, ry1, glyph: run
      scr.blend_region s.opacity, Math.max(i, xl), l, ry0, ry1, glyph: right_cap
    end

    # Registers on the window the rows where this widget emits horizontal
    # line-drawing chars, so the docking pass joins them with crossing chars from
    # neighbors. Only rows with horizontal segments need registering (verticals
    # dock when a horizontal stop crosses them). Base registers top/bottom rows
    # of a line-type border; widgets drawing lines otherwise override this.
    protected def register_dock_stops(coords : RenderedGeometry)
      style.border.try do |border|
        if border.any? && border.type.solid?
          # A widget rendering into a compositing plane registers on the *plane*
          # stops so overlay borders join each other but not the base content
          # beneath; a base-layer widget uses the window stops. The gate must be
          # the window's `compositing_layers?`, NOT this widget's `@compositing`
          # (set only on the layer root) — else a bordered descendant registers
          # on the BASE stops and docks to base content, producing stray
          # junctions.
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
      Docking.dock scr.lines, stops, scr.awidth, contrast, ascii: scr.glyph_tier.ascii?
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
    protected def border_char(border, g, in_top, in_bot, in_left, in_right)
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
    # `ProgressBar`, `Gradient`). Returns the render's `RenderedGeometry` (or `nil` when
    # nothing was rendered). Use `next` inside the block to bail out early while
    # still returning the coords.
    # Shared body of `with_inner_coords`/`with_content_coords`: runs the base
    # `_render` (forwarding *with_children*), bails when nothing rendered, then
    # insets the resulting coordinates by this widget's border — and, when *pad*
    # is true, additionally by the padding — before yielding the interior
    # rectangle `(xi, xl, yi, yl)`. Returns the render's `RenderedGeometry` (or `nil`).
    #
    # The inset is strictly by-value: `ret` is this widget's cached `@lpos`, and
    # `Border#adjust(pos)`/`Padding#adjust(pos)` would shrink it in place, so
    # mutating it would permanently collapse `@lpos` to the interior,
    # under-reporting mouse hit-testing, damage-tracking bounds, and
    # `clear_last_rendered_position` until the next frame. The allocation-free
    # by-value overloads used here leave `@lpos`/`ret` describing the full rect.
    private def with_inset_coords(with_children, pad : Bool, & : (Int32, Int32, Int32, Int32) -> _) : RenderedGeometry?
      ret = _render with_children
      return unless ret
      xi, xl, yi, yl = ret.xi, ret.xl, ret.yi, ret.yl
      if border = style.border
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl
      end
      if pad
        xi, xl, yi, yl = style.padding.adjust xi, xl, yi, yl
      end
      yield xi, xl, yi, yl
      ret
    end

    def with_inner_coords(& : (Int32, Int32, Int32, Int32) -> _) : RenderedGeometry?
      with_inset_coords(true, false) { |xi, xl, yi, yl| yield xi, xl, yi, yl }
    end

    # Like `with_inner_coords`, but insets the rendered rectangle by the border
    # AND the padding — the interior *content* region, matching the two-step
    # inset `_render` itself applies (border first, then padding) before laying
    # out content. Yields `(xi, xl, yi, yl)` for a widget that paints its own
    # content straight into the cell buffer on top of the standard render (e.g.
    # `Effect::Direct`). Returns the render's `RenderedGeometry` (or `nil` when nothing was
    # rendered). `with_children` is forwarded to `_render` so an interior-painting
    # widget can still opt out of rendering its children.
    def with_content_coords(with_children = true, & : (Int32, Int32, Int32, Int32) -> _) : RenderedGeometry?
      with_inset_coords(with_children, true) { |xi, xl, yi, yl| yield xi, xl, yi, yl }
    end

    # The 7-predicate SGR flag word for *style* (visible?/reverse?/blink?/
    # underline?/italic?/strike?/bold?), independent of any fg/bg. Factored out
    # of `#style_to_attr` so a caller that needs the packed attr for several fg/bg
    # combinations of the *same* style (e.g. a widget's four border sides,
    # which all share `border` as the style object) can compute this once and
    # reuse it via `#pack_attr`, instead of paying for the predicate calls
    # again on every combination.
    def self.style_to_attr_flags(style) : Int32
      # TODO support style.* being Procs ?
      # `visible` lives on `Style` proper, not the shared SGR mixin: a `Border`
      # passed here (a widget's four sides share it as the style object) has no
      # `visible?` and is always drawn. `responds_to?` resolves at compile time.
      ((style.responds_to?(:visible?) && !style.visible?) ? Attr::INVISIBLE : 0) |
        (style.reverse? ? Attr::REVERSE : 0) |
        (style.blink? ? Attr::BLINK : 0) |
        (style.underline? ? Attr::UNDERLINE : 0) |
        (style.italic? ? Attr::ITALIC : 0) |
        (style.strike? ? Attr::STRIKE : 0) |
        (style.bold? ? Attr::BOLD : 0)
    end

    # Packs a precomputed flag word (see `#style_to_attr_flags`) together with
    # *fg*/*bg* into a full attr, applying the same "both unset falls back to
    # the style's own fg/bg" rule as `#style_to_attr`.
    def self.pack_attr(flags : Int32, style, fg = nil, bg = nil) : Int64
      if fg.nil? && bg.nil?
        fg = style.fg
        bg = style.bg
      end

      # `fg`/`bg` are already native colors (`0xRRGGBB` int, `-1` for terminal
      # default, `nil` for unset). `Attr.pack_color` packs that into a color
      # field; no per-frame string parsing.
      Attr.pack(flags, Attr.pack_color(fg || -1), Attr.pack_color(bg || -1))
    end

    def self.style_to_attr(style, fg = nil, bg = nil) : Int64
      pack_attr style_to_attr_flags(style), style, fg, bg
    end

    def style_to_attr(style, fg = nil, bg = nil)
      self.class.style_to_attr style, fg, bg
    end

    # Where this widget last painted, with the absolute offsets (`aleft`/`atop`/
    # `aright`/`abottom`/`awidth`/`aheight`) and insets resolved from the raw
    # rectangle, or `nil` if it has no rendered position — never rendered, or
    # last frame it resolved to nothing (fully clipped/off-window). `#lpos` is
    # the same object *without* the resolved fields.
    #
    # The `a*` fields are filled lazily and cached in the `RenderedGeometry`
    # itself; `RenderedGeometry#reset` clears them, so a widget that moves
    # re-resolves rather than reporting the previous frame's absolutes.
    #
    # Returns the widget's **live `@lpos`**, which the next render mutates in
    # place: read the values, do not retain the object across frames.
    def last_rendered_position? : RenderedGeometry?
      pos = @lpos || return nil

      # Already resolved for this rectangle.
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

      pos
    end

    # :ditto:, raising when the widget has no rendered position. Use this when a
    # rendered position is a precondition (the geometry resolution path, which
    # only reaches here for an already-rendered ancestor); use
    # `#last_rendered_position?` when it is merely likely.
    def last_rendered_position : RenderedGeometry
      last_rendered_position? ||
        raise "Widget has no rendered position (never rendered, or fully clipped last frame); use #last_rendered_position? instead"
    end

    # Clears area/position of widget's last render
    def clear_last_rendered_position(*, rendered : Bool = false, force : Bool = false)
      return unless window?
      # Reuse the cached `@lpos` from the previous `_render` instead of
      # recomputing geometry from scratch — it's still correct even after the
      # caller moved the widget, since `@lpos` holds where it actually painted.
      # Falls back to `coords` only when never rendered. Same
      # `@lpos || coords` idiom as `widget_scrolling.cr`.
      lpos = @lpos || coords(rendered)
      return unless lpos
      window.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, force: force)
    end
  end
end
