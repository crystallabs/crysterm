module Crysterm
  class Widget
    # module Rendering
    include Crystallabs::Helpers::Alias_Methods

    # Per-widget override of the overflow action; `nil` = inherit the window
    # default. Read through `#overflow`.
    @overflow : Overflow? = nil

    # Reused stops set for `#merge_junction_rows`, cleared per call. Lazily allocated on
    # first use (many widgets never dock rows).
    @_merge_junction_rows_stops : Hash(Int32, Bool)? = nil

    # Single-slot custom-paint hook; see `#paint_handler`.
    @paint_handler : ((Int32, Int32, Int32, Int32) ->)? = nil

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
      return value if value == @overflow
      @overflow = value
      # Whether this widget clips its children (overflow: Hidden) changed → its
      # subtree's nearest clipping ancestor may differ.
      invalidate_clip_ancestor_cache
      update
      value
    end

    def overflow=(value : ::Crystallabs::Helpers::Enums::Shorthands)
      self.overflow = ::Crystallabs::Helpers::Enums.from(Overflow, value)
    end

    # Layout engine arranging this widget's children, or `nil` for manual
    # placement, in which case `#base_render` uses `Layout::Manual`. Mirrors Qt's
    # null `QWidget::layout()`.
    @layout : Crysterm::Layout? = nil

    # :ditto:
    def layout : Crysterm::Layout?
      @layout
    end

    # Symbol shorthand of `#layout=`: `w.layout = :vbox` — see `Layout.from`.
    def layout=(value : Symbol) : Crysterm::Layout?
      self.layout = Crysterm::Layout.from value
    end

    # :ditto: — change-guarded. Installs the layout's `#container` back-pointer
    # (and clears the outgoing one), then schedules a repaint so the newly
    # installed engine arranges the children.
    def layout=(value : Crysterm::Layout?) : Crysterm::Layout?
      return value if value == @layout
      @layout.try(&.container=(nil))
      @layout = value
      css_note_geometry_write layout: value
      value.try(&.container=(self))
      # The outgoing engine's assignments must not shadow the children's own
      # specs under the new engine (or under manual placement, for `nil`) —
      # e.g. a swapped-in `UniformGrid` measures child widths before its first
      # placement pass would overwrite them. Quiet; the `update` below repaints.
      @children.each &.clear_layout_geometry
      update
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
      update
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

    # Docks this widget to a `Layout::Dock` region, wrapping *region* in a
    # `Layout::Dock::Hint`:
    #
    # ```
    # Widget::Box.new parent: frame, height: 1, layout_hint: :top
    # ```
    #
    # Qt spells the same thing `addWidget(w, BorderLayout::North)`. Takes the
    # same shorthand forms as `#align`/`#overflow` (`:top`, `"top"`). The
    # `Layout::Hint` overload serves engines with richer hints (Grid's
    # cell+span, flex grow).
    def layout_hint=(region : Crysterm::Layout::Dock::Region) : Crysterm::Layout::Hint?
      self.layout_hint = Crysterm::Layout::Dock::Hint.new region
    end

    # :ditto:
    def layout_hint=(region : ::Crystallabs::Helpers::Enums::Shorthands) : Crysterm::Layout::Hint?
      self.layout_hint = ::Crystallabs::Helpers::Enums.from Crysterm::Layout::Dock::Region, region
    end

    # A parent always renders before its children, so a child may reuse the
    # parent's `lpos` rather than recomputing it (which mishandles content
    # shrinkage). Stale if the parent is moved afterwards.

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

    # Splits one edge's scroll-clipped run (`RenderedGeometry#hidden_*`) across
    # that edge's border and padding bands — the border is the outermost band,
    # so it is consumed first. Returns `{visible_border, visible_padding}`: the
    # parts of each band still inside the clipping ancestor's viewport, i.e. the
    # effective insets to apply in place of the full widths. Equals
    # `{border_w, padding_w}` on an unclipped edge (`hidden == 0`), so callers
    # need no clipped/unclipped distinction.
    protected def effective_edge_insets(border_w : Int32, padding_w : Int32, hidden : Int32) : {Int32, Int32}
      eb = (border_w - hidden).clamp(0, border_w)
      ep = (padding_w - Math.max(hidden - border_w, 0)).clamp(0, padding_w)
      {eb, ep}
    end

    # All four edges' `#effective_edge_insets` for *rect*, with the border
    # additionally *fitted* to the box: a cell-grid border can't be drawn
    # thinner than a whole cell, so an axis whose box is too small to hold even
    # both of its edges would render half a frame and swallow the widget whole
    # — a QSS-themed one-row `ProgressBar` (`QProgressBar { border: 1px solid }`)
    # comes out as a lone hollow line with no room left for its fill. Drop that
    # axis' border rather than the content; a box exactly as deep as its two
    # edges still keeps them (the classic empty framed box).
    #
    # `capped_v`/`capped_h` record that a *collapse actually happened* while the
    # perpendicular pair survived, so the surviving edges stand alone with no
    # corners to close them. The border painter draws those with the cap glyphs
    # rather than the line-family runs (see `Border#glyph_octet`) — `│` belongs
    # to a family that implies corners, so a lone pair reads as a broken frame.
    # Fast guard: nothing to inset — no border, no padding, no scroll-hidden
    # band. The overwhelmingly common widget, and this runs twice per widget
    # per frame (`base_render` + `with_inset_coords`), so the guard folds into
    # the caller (no call, no by-memory `Insets` return) and only widgets that
    # actually inset pay the outlined four-edge fitting math.
    @[AlwaysInline]
    protected def effective_insets(border, padding, rect : RenderedGeometry) : Insets
      if !border.any? && !padding.any? &&
         rect.hidden_left == 0 && rect.hidden_top == 0 &&
         rect.hidden_right == 0 && rect.hidden_bottom == 0
        return Insets.new({0, 0}, {0, 0}, {0, 0}, {0, 0}, capped_v: false, capped_h: false)
      end
      effective_insets_slow border, padding, rect
    end

    # The inset-bearing arm of `#effective_insets`.
    protected def effective_insets_slow(border, padding, rect : RenderedGeometry) : Insets
      l = effective_edge_insets(border.left, padding.left, rect.hidden_left)
      t = effective_edge_insets(border.top, padding.top, rect.hidden_top)
      r = effective_edge_insets(border.right, padding.right, rect.hidden_right)
      b = effective_edge_insets(border.bottom, padding.bottom, rect.hidden_bottom)
      drop_x = rect.xl - rect.xi < l[0] + r[0]
      drop_y = rect.yl - rect.yi < t[0] + b[0]
      l, r = {0, l[1]}, {0, r[1]} if drop_x
      t, b = {0, t[1]}, {0, b[1]} if drop_y
      Insets.new(l, t, r, b,
        capped_v: drop_y && (l[0] > 0 || r[0] > 0),
        capped_h: drop_x && (t[0] > 0 || b[0] > 0))
    end

    # One render's effective (visible, border-fitted) insets: a `{border,
    # padding}` cell pair per edge, in the sided order `Border`/`Padding`
    # themselves use, plus the two cap flags `#effective_insets` sets.
    record Insets,
      left : {Int32, Int32},
      top : {Int32, Int32},
      right : {Int32, Int32},
      bottom : {Int32, Int32},
      capped_v : Bool,
      capped_h : Bool

    # The base painting implementation: renders this widget (and, when
    # *with_children*, its subtree) into the window's cell buffer. Subclass
    # `#paint` overrides call this the way a `paintEvent` override calls the
    # base class — it never dispatches back into `#paint`, so an override can
    # run it and then paint on top. External callers use `#repaint` (sync) or
    # `#update` (scheduled) instead.
    # ameba:disable Metrics/CyclomaticComplexity
    protected def base_render(with_children = true)
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

      # This paint reflects the style source as of now — stamp the watermark
      # the damage sweep compares against (see `#capture_painted_style`).
      capture_painted_style

      # Keep any border label glued to the (possibly CSS-resolved) top inset.
      # Must run before the label child renders.
      sync_label_position

      # `awidth(rendered: true)` is an O(1) read of the parent's already-rendered cached
      # `lpos`. Resolve once and pass to both `process_content` and `coords`
      # instead of each walking the ancestor chain separately.
      aw = awidth(rendered: true)
      process_content awidth_hint: aw

      # Pass `@lpos` so `coords` updates it in place rather than allocating a
      # fresh `RenderedGeometry` every frame.
      coords = coords(rendered: true, into: @lpos, width_hint: aw)
      unless coords
        # No on-screen rect this frame (scrolled/clipped out of a scrollable
        # ancestor's viewport, or the ancestor has no `lpos`): this widget and
        # its descendants paint nowhere, so clear their last-rendered rects, or
        # `Window#widget_at` keeps routing clicks/hovers to the stale subtree
        # rects. Layout-excluded chrome renders out-of-band with its own live
        # `lpos`, so leave it untouched.
        @lpos = nil
        clear_children_lpos
        return
      end

      if coords.xl - coords.xi <= 0
        coords.xl = Math.max(coords.xl, coords.xi)
        # Our own zero-width rect is un-hittable, but descendants would keep the
        # previous frame's rects (see above).
        clear_children_lpos
        return
      end

      if coords.yl - coords.yi <= 0
        coords.yl = Math.max(coords.yl, coords.yi)
        clear_children_lpos
        return
      end

      # `window` walks the parent chain on every call; bind it once. The style
      # values below are constant for the render, so hoist them out of the
      # per-cell loops.
      scr = window
      # No-op unless an `animation` is declared.
      ensure_css_animation

      lines = scr.cell_rows
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
      # stale, caching into `@printable_content`. Once per frame, not per appended line.
      pcontent = self.pcontent
      # Reuse the cached codepoint index unless `@printable_content` was reparsed into a
      # fresh `String` (identity check).
      content = @_content_index
      unless content && content.built_from?(pcontent)
        content = StringIndex.new pcontent
        @_content_index = content
      end
      bch = style.fill_char
      # `ci[base]` is the codepoint offset in the full content where the first
      # visible wrapped line starts. `coords.base` can transiently sit at or past
      # the end (a scroll left below the last line by an in-flight resize/reflow):
      # there the content starts past the end, so clamp to the content length. In
      # range the lookup is always a valid `Int32` (`ci` is `Array(Int32)`, so the
      # `[]?` is nil only when out of range — handled above); the `|| 0` is a bare
      # guard for a non-sensical negative base and never fires in practice.
      ci =
        if coords.base >= @wrapped_lines.ci.size
          content.size
        else
          @wrapped_lines.ci[coords.base]? || 0
        end

      @lpos = coords

      register_junction_stops coords

      # `process_content` already cached `style_to_attr(self.style)` in `@_parse_attr_default`;
      # reuse it unless a parent substituted a style. `|| style_to_attr(style)` is a
      # defensive fallback.
      default_attr = (style.same?(own_style) ? @_parse_attr_default : nil) || style_to_attr(style)
      attr = default_attr

      # If we're in a scrollable text box, check to
      # see which attributes this line starts with.
      if ci > 0
        attr = @wrapped_lines.attr.try(&.[Math.min(coords.base, @wrapped_lines.size - 1)]?) || default_attr
      end

      # Effective per-edge insets: on a scroll-clipped edge part (or all) of the
      # border/padding band is hidden past the ancestor's viewport, and `coords`
      # clamps the rect to that viewport (recording the cut in `hidden_*`), so
      # the inset still to apply here is only each band's visible remainder.
      # Unclipped edges get the full widths. These replace the whole-width
      # `border.adjust`/`p.adjust` calls, which would double-count the hidden
      # rows/columns and start content too far in (or paint phantom padding).
      sb = style.border
      insets = effective_insets(sb, padding, coords)
      ebl, epl = insets.left
      ebt, ept = insets.top
      ebr, epr = insets.right
      ebb, epb = insets.bottom

      xi += ebl
      xl -= ebr
      yi += ebt
      yl -= ebb

      # Reserve the bottom row(s) for a shown horizontal scroll bar so content
      # never paints under it. `may_scroll` also stays true for a widget that
      # *was* scrollable, so its bar gets hidden when scrolling is turned off.
      # Must be computed before the pre-fill, which needs `hsr` to size the
      # bottom band.
      may_scroll = scrollable? || !@scrollbar_widget.nil? || !@horizontal_scrollbar_widget.nil?
      # Resolve the two bar-visibility predicates once for this frame. Each runs
      # the overflow tests (`content_width`/`scroll_*` + `awidth` walks), and they
      # are otherwise recomputed 4-5×/frame (here + twice inside
      # `update_scrollbar_widget`). Gated on `may_scroll` so a non-scrollable
      # widget with no bars pays nothing. Threaded into `hscrollbar_rows`'s job
      # and `update_scrollbar_widget` below.
      show_v_scrollbar = may_scroll && show_scrollbar?
      show_h_scrollbar = may_scroll && show_horizontal_scrollbar?
      hsr = show_h_scrollbar ? scrollbar_height : 0

      # Padding/valign make the content loop skip some cells/lines, so fill
      # those ahead of time. On the common opaque-fill path only the padding
      # bands and the scrollbar-reserved rows need pre-filling (the loop paints
      # the valign gap itself — a negative `ci` indexes to nil, i.e. the `bch`
      # fill). A background-image widget keeps the whole-box fill; a
      # `fill: false` widget must not be filled at all. The `hsr > 0` arm covers
      # the no-padding default-align case: the reserved bar band (including the
      # corner cell a shortened bar leaves to us) still needs the widget's own
      # background.
      if padding.any? || !@align.top? || hsr > 0
        if (opacity = style_opacity) && fill
          # Pre-blend only the bands the content loop won't reach: it blends the
          # content region itself, and blending twice makes a padded translucent
          # widget's interior more opaque than its padding. A background-image
          # widget's content loop leaves empty cells untouched, so there the
          # whole-box blend must stay. Band widths use the effective (visible)
          # padding: a scroll-clipped edge's hidden padding rows/columns are
          # outside the rect and must not re-appear as a band inside it.
          skip_content = style.background_image.nil?
          cxi = xi + epl
          cxl = xl - epr
          cyi = yi + ept
          cyl = yl - epb - hsr
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
          bot = epb + hsr
          # Effective (visible) padding widths: a scroll-clipped edge's hidden
          # padding band must not be re-painted inside the viewport as a
          # phantom blank band over rows/columns that belong to content.
          # Degenerate boxes (padding thicker than the box) make bands overlap
          # or ranges invert; `fill_region` clamps and empty ranges no-op, and a
          # double-filled cell is change-skipped on the second write.
          scr.fill_region(default_attr, bch, xi, xl, yi, yi + ept) if ept > 0
          scr.fill_region(default_attr, bch, xi, xl, yl - bot, yl) if bot > 0
          scr.fill_region(default_attr, bch, xi, xi + epl, yi + ept, yl - bot) if epl > 0
          scr.fill_region(default_attr, bch, xl - epr, xl, yi + ept, yl - bot) if epr > 0
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

      # Effective padding, for the same reason as the border inset above.
      xi += epl
      xl -= epr
      yi += ept
      yl -= epb
      yl -= hsr

      # Determine where to place the text if it's vertically aligned.
      if @align.v_center? || @align.bottom?
        visible = yl - yi
        if @wrapped_lines.size < visible
          if @align.v_center?
            visible = visible // 2
            visible -= @wrapped_lines.size // 2
          elsif @align.bottom?
            visible -= @wrapped_lines.size
          end
          ci -= visible * (xl - xi)
        end
      end

      # Whether this widget is the selected item of a parent list, in which case
      # content keeps the default foreground (only bg/flags follow inline SGR).
      # Resolved once here instead of re-walking the parent chain per SGR escape.
      keep_selected_fg = parent.try do |parent2|
        parent2.item_view? && parent2.interactive? && parent2.item_selected?(self)
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

        # (Cells stay allocated for the whole row rather than created lazily per
        # drawn glyph: the frame diff and damage tracking compare against a dense
        # previous-frame buffer, so a sparse model would complicate both for no
        # clear win — see the always-allocated `alloc`/`Row` buffers.)
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
            if content[ci]? == '[' && (m = SGR.terminator(content, ci + 1))
              # `m` is the index of the trailing 'm'. Parse params straight out of
              # `content` (no substring), then advance past the 'm'.
              attr = SGR.to_attr(content, ci - 1, m, attr, default_attr)
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
            # A literal TAB reaching the render stream is a rare fallback:
            # content normally has its tabs expanded to `tab_char * tab_size` up
            # front in `clean_content_chars`, so by here they are already spaces.
            # Painting a stray one as a single fill cell — rather than expanding
            # to `tab_size` cells inside this one-cell-per-iteration loop — keeps
            # the column accounting simple; real tab-width handling lives in that
            # pre-expansion pass.
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
            elsif sel_cols.nil? && style_opacity.nil?
              # Plain row tail: with no selection `highlighted_attr` is `attr`
              # itself and with no opacity every remaining cell is written the
              # same constant `{attr, ch}` (`ch` is `bch` here) — exactly
              # `fill_region`'s contract, and the same sweep the
              # content-exhausted fast path above already takes. `fill_region`
              # clamps a negative origin and stops at the row's end, matching
              # the per-cell loop's `x < 0` skip and its break on the first
              # missing cell; `x = xl` then ends the row as the loop's own
              # run-to-`xl` does, with the content index untouched either way.
              scr.fill_region(attr, ch, Math.max(x, 0), xl, y, y + 1) if draw_row
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
      update_scrollbar_widget(show_v_scrollbar, show_h_scrollbar) if may_scroll

      # Restore the outer box by undoing the effective border+padding insets
      # applied above (same effective widths, so this lands exactly back on the
      # clamped `lpos` rect — never past a clipped edge's viewport).
      xi -= ebl + epl
      xl += ebr + epr
      yi -= ebt + ept
      yl += ebb + epb

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
        # glyph + fg are drawn over it. An inner-aligned block/braille border
        # defaults to this ground: its ink hugs the content, so by definition
        # the cell remainder shows what's behind the widget — unless an
        # explicit bg overrides.
        border_bg_transparent = border.bg == -1 ||
                                (border.bg.nil? && border.transparent_ground_default?)

        # The light this widget's relief shading and weight bevel follow
        # (style override, else the window's scene light).
        light = effective_light(style)

        # Per-side attributes so `border-top-color` etc. can differ, each falling
        # back to the whole-border color. Border bg falls back to the widget's
        # own bg (not the terminal default), so a themed frame sits flush with
        # its interior.
        border_bg = border.bg || style.bg
        # All four sides share `border` as the style object, so the SGR flag word
        # is identical across them — computed once, with only the fg per side.
        border_flags = self.class.style_to_attr_flags(border)
        # `side_fg` resolves any `currentColor` marker against the widget's
        # effective text color at render time (CSS computed-value semantics —
        # the final `color` wins regardless of declaration order).
        el_fg = style.fg
        top_attr = self.class.pack_attr border_flags, border, border.side_fg(Side::Top, el_fg, light), border_bg
        bottom_attr = self.class.pack_attr border_flags, border, border.side_fg(Side::Bottom, el_fg, light), border_bg
        left_attr = self.class.pack_attr border_flags, border, border.side_fg(Side::Left, el_fg, light), border_bg
        right_attr = self.class.pack_attr border_flags, border, border.side_fg(Side::Right, el_fg, light), border_bg

        # The eight border glyphs with any per-position char overrides (CSS
        # `border-chars`/`border-top-left-char` …) merged over them, resolved
        # once for the whole box rather than per cell — and for the border's own
        # medium only, so a `Fill` border doesn't build (and discard) the
        # line-family octet.
        glyphs = border.glyph_octet(glyph_tier, insets.capped_v, insets.capped_h,
          octants: glyph_octants?, light: light)

        # Interior (content) rectangle: the outer box `(xi..xl, yi..yl)` inset by
        # each side's *visible* thickness (a clipped edge's hidden band rows are
        # already cut off the rect, so insetting by the full width would push
        # the interior — and the left/right vertical runs — short of the
        # viewport edge). Every cell of the outer box outside it is a border
        # cell, so a side thicker than one cell fills its whole band.
        in_yi = yi + ebt
        in_yl = yl - ebb
        in_xi = xi + ebl
        in_xl = xl - ebr

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

            # Which memberships carry the *rule* at this cell's band depth
            # (`Border#band_rule?`): at the classic 1-cell widths every band
            # cell does; a thicker band rules only the ring its alignment
            # picks, leaving the other band cells as ground.
            rule_t = in_top && border.band_rule?(y - yi, ebt)
            rule_b = in_bot && border.band_rule?(yl - 1 - y, ebb)
            rule_l = in_left && border.band_rule?(x - xi, ebl)
            rule_r = in_right && border.band_rule?(xl - 1 - x, ebr)
            ch = border_rule_char border, glyphs, rule_t, rule_b, rule_l, rule_r,
              in_top, in_bot, in_left, in_right, x - xi, y - yi
            # `Glyphs::NONE` marks a cell the border deliberately leaves
            # untouched — an Inner corner whose junction rectangle is too
            # small for any repertoire piece (`Glyphs.corner_fit` → `:gap`).
            if ch == Glyphs::NONE
              x += 1
              next
            end
            # `nil` is band ground (an off-ring band cell, or a dashed run's
            # gap): the border bg without a glyph — or, on a transparent
            # ground, no paint at all (the backdrop cell survives whole).
            if ch.nil?
              if border_bg_transparent
                x += 1
                next
              end
              ch = ' '
            end
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
      # bounds. A band on a scroll-clipped (`no_*`) edge is skipped: shadows
      # intentionally paint *outside* the rect, so on a clipped edge the band
      # would land past the clipping ancestor's viewport, over cells that
      # belong to other widgets.
      if s = style.shadow
        # The sides the shadow falls on: explicit extents verbatim, or — for
        # an auto shadow (`shadow: true`, the `Floating` look) — the sides
        # facing away from the light (`Shadow#resolved_sides`).
        shadow_light = effective_light(style)
        sl, st, sr, sb = s.resolved_sides(shadow_light)
        # A Spot light's rays diverge like a cone, so an auto shadow's
        # silhouette comes out one cell larger than the widget: each band
        # spills one cell past each *free* end (an end not already joined to
        # a perpendicular shadow band, which owns their shared corner) and
        # drops the directional silhouette shift. Explicit sides keep the
        # classic directional geometry regardless.
        spot = s.auto_sides? && shadow_light.kind.spot?
        if sl > 0 || st > 0 || sr > 0 || sb > 0
          # Half-block (thin) shadow: each band splits into the straight run
          # alongside the box and the corner caps beyond its edges, so the cell
          # where two bands meet gets its own diagonal glyph. Corner ownership
          # follows the band partition, so no cell is painted twice. The plain
          # (no-glyphs) path does a single blend per band instead.
          #
          # The per-band glyphs — explicit chars merged over any `Shadow#ratio`
          # derivation — resolve once for all four bands; a `nil` position falls
          # back to the full-cell blend inside `blend_region`.
          sg = s.glyphs? ? s.glyph_octet(glyph_tier, octants: glyph_octants?) : nil
          if sl > 0 && !coords.no_left?
            if spot
              i = st > 0 ? yi - st : yi - 1
              l = sb > 0 ? yl + sb : yl + 1
            else
              i = (yi - st) + (sb > 0 && st == 0 && sr == 0 ? sb : 0)
              l = sb > 0 ? yl + sb : yl - (st > 0 && sb == 0 ? st : 0)
            end
            if sg
              blend_shadow_v scr, s, xi - sl, xi, i, l, yi, yl, sg[:l], sg[:tl], sg[:bl]
            else
              scr.blend_region s.opacity, xi - sl, xi, Math.max(i, 0), l
            end
          end

          if st > 0 && !coords.no_top?
            if spot
              i = sl > 0 ? xi : xi - 1
              l = sr > 0 ? xl + sr : xl + 1
            else
              i = xi
              l = sr > 0 ? xl + sr : (sl > 0 ? xl - sl : xl)
            end
            if sg
              blend_shadow_h scr, s, i, l, yi - st, yi, xi, xl, sg[:t], sg[:tl], sg[:tr]
            else
              scr.blend_region s.opacity, Math.max(i, 0), l, yi - st, yi
            end
          end

          if sr > 0 && !coords.no_right?
            if spot
              i = st > 0 ? yi : yi - 1
              l = sb > 0 ? yl + sb : yl + 1
            else
              i = (st > 0 || sl > 0) ? yi : yi + sb
              l = sb > 0 ? yl + sb : yl
            end
            if sg
              blend_shadow_v scr, s, xl, xl + sr, i, l, yi, yl, sg[:r], sg[:tr], sg[:br]
            else
              scr.blend_region s.opacity, xl, xl + sr, Math.max(i, 0), l
            end
          end

          if sb > 0 && !coords.no_bottom?
            if spot
              i = sl > 0 ? xi : xi - 1
              l = sr > 0 ? xl : xl + 1
            else
              i = sr > 0 ? xi + (sl > 0 ? 0 : sr) : xi
              l = xl - (sl > 0 && st == 0 && sr == 0 ? sl : 0)
            end
            if sg
              blend_shadow_h scr, s, i, l, yl, yl + sb, xi, xl, sg[:b], sg[:bl], sg[:br]
            else
              scr.blend_region s.opacity, Math.max(i, 0), l, yl, yl + sb
            end
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
    # A `Glyphs::NONE` cap means "no corner paint at all" (`Glyphs.corner_fit`
    # → `:gap` for a hairline shadow): its sub-range is skipped outright,
    # leaving the backdrop cells untouched — distinct from a `nil` cap, which
    # paints the classic full-cell blend.
    private def blend_shadow_v(scr, s, cx0, cx1, i, l, yi, yl, run, top_cap, bot_cap)
      scr.blend_region s.opacity, cx0, cx1, i, Math.min(l, yi), glyph: top_cap unless top_cap == Glyphs::NONE
      scr.blend_region s.opacity, cx0, cx1, Math.max(i, yi), Math.min(l, yl), glyph: run
      scr.blend_region s.opacity, cx0, cx1, Math.max(i, yl), l, glyph: bot_cap unless bot_cap == Glyphs::NONE
    end

    # :ditto: for a horizontal (top/bottom) band in rows *ry0*...*ry1*, columns
    # *i*...*l*, split at the box's own column span *xi*...*xl* (run + left/right
    # corner caps).
    private def blend_shadow_h(scr, s, i, l, ry0, ry1, xi, xl, run, left_cap, right_cap)
      scr.blend_region s.opacity, i, Math.min(l, xi), ry0, ry1, glyph: left_cap unless left_cap == Glyphs::NONE
      scr.blend_region s.opacity, Math.max(i, xi), Math.min(l, xl), ry0, ry1, glyph: run
      scr.blend_region s.opacity, Math.max(i, xl), l, ry0, ry1, glyph: right_cap unless right_cap == Glyphs::NONE
    end

    # Registers on the window the rows where this widget emits horizontal
    # line-drawing chars, so the docking pass joins them with crossing chars from
    # neighbors. Only rows with horizontal segments need registering (verticals
    # dock when a horizontal stop crosses them). Base registers top/bottom rows
    # of a line-type border; widgets drawing lines otherwise override this.
    protected def register_junction_stops(coords : RenderedGeometry)
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
          stops = scr.compositing_layers? ? scr.plane_junction_stops : scr.junction_stops
          stops[coords.yi] = true
          stops[coords.yl - 1] = true
        end
      end
    end

    # Re-joins the line-drawing characters on the given window *rows* into
    # seamless junctions (`├ ┤ ┬ ┼` …), reusing the window's `Junctions` component
    # on demand for one widget. Lets a widget connect interior line art (e.g. a
    # `Menu`'s separator rules) to its own border. No-op when detached or given
    # no rows.
    #
    # *contrast* defaults to `JunctionContrast::Ignore` (only the glyph changes,
    # not cell colors) rather than the window's global setting — `Blend` would
    # diffuse the junction's color along the whole run, muddying e.g. a
    # separator's divider color.
    protected def merge_junction_rows(rows : Enumerable(Int32), contrast : JunctionContrast = JunctionContrast::Ignore) : Nil
      scr = window? || return
      # Reuse a per-widget Hash instead of allocating one per frame. Single
      # fiber renders, so the scratch set is never live across calls.
      stops = (@_merge_junction_rows_stops ||= {} of Int32 => Bool)
      stops.clear
      rows.each { |y| stops[y] = true }
      return if stops.empty?
      Junctions.merge scr.cell_rows, stops, scr.awidth, contrast, ascii: scr.glyph_tier.ascii?
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
    #
    # *g* is the border's `Border#glyph_octet` — one glyph per side and per
    # corner, with the border's char overrides already merged in through its
    # family's fall-back chain, resolved once by the caller. So this is a pure
    # 8-way select with no per-cell family dispatch.
    protected def border_char(g, in_top, in_bot, in_left, in_right)
      h_band = in_top || in_bot
      v_band = in_left || in_right

      if h_band && v_band
        if in_top
          in_left ? g[:tl] : g[:tr]
        else
          in_left ? g[:bl] : g[:br]
        end
      elsif h_band
        in_top ? g[:t] : g[:b]
      else
        in_left ? g[:l] : g[:r]
      end
    end

    # `border_char` with the band-*rule* flags in place of raw memberships
    # (see `Border#band_rule?`), returning `nil` for a ground cell: one on
    # no ruled ring, one an inner-aligned ring's runs don't reach
    # (`Border#inner_band_ring?` — the raw *in_\** memberships say the cell
    # sits in a perpendicular band, outward of the ring's corner), or a run
    # cell a dashed/dotted block stroke gaps (`Border#run_gap?`;
    # *off_x*/*off_y* are the cell's offsets from the box edges, keeping
    # opposite runs in phase). Corners are always drawn.
    protected def border_rule_char(border, g, rule_t, rule_b, rule_l, rule_r,
                                   in_top, in_bot, in_left, in_right, off_x, off_y) : Char?
      h_band = rule_t || rule_b
      v_band = rule_l || rule_r

      if h_band && v_band
        if rule_t
          rule_l ? g[:tl] : g[:tr]
        else
          rule_l ? g[:bl] : g[:br]
        end
      elsif h_band
        return if (in_left || in_right) && border.inner_band_ring?
        return if border.run_gap?(off_x)
        rule_t ? g[:t] : g[:b]
      elsif v_band
        return if (in_top || in_bot) && border.inner_band_ring?
        return if border.run_gap?(off_y)
        rule_l ? g[:l] : g[:r]
      end
    end

    # Custom-paint hook: a single overwritable slot (hence `*_handler`, cf.
    # the `stop_handler` convention) invoked after the standard box/content
    # pass with the widget's *content* rectangle `(xi, xl, yi, yl)` — the
    # interior inside border and padding. It lets an instance paint custom
    # cells without subclassing and overriding `#paint`:
    #
    # ```
    # w.paint_handler do |xi, xl, yi, yl|
    #   w.window.fill_region w.style.attr, '·', xi, xl, yi, yl
    # end
    # ```
    #
    # (`Canvas#on_paint` is the raster/vector counterpart — it hands the block
    # a `Painter` over a pixel bitmap instead of a cell rectangle.)
    def paint_handler(&block : (Int32, Int32, Int32, Int32) ->) : self
      @paint_handler = block
      self
    end

    # Clears the custom-paint hook installed by `#paint_handler`.
    def clear_paint_handler : Nil
      @paint_handler = nil
    end

    # Paints this widget synchronously into the window's cell buffer. This is
    # the polymorphic paint entry — subclasses override it (keeping the
    # `(with_children = true)` signature, or the call is an overload rather
    # than an override) and invoke `#base_render` for the standard box/content
    # pass. Callers outside the render pipeline should prefer `#repaint` (the
    # Qt-named public spelling) or, for a coalesced scheduled frame, `#update`.
    def paint(*, with_children = true)
      if handler = @paint_handler
        with_content_coords(with_children) { |xi, xl, yi, yl| handler.call(xi, xl, yi, yl) }
      else
        base_render with_children
      end
    end

    # Synchronously paints this widget ↔ `QWidget::repaint()` — dispatches to
    # the (possibly overridden) `#paint`. For a coalesced, scheduled frame of
    # the whole window use `#update`.
    def repaint(*, with_children = true)
      paint with_children: with_children
    end

    # Runs `base_render`, insets the resulting coordinates by this widget's
    # border, and yields the interior rectangle `(xi, xl, yi, yl)` for a widget
    # that paints its own interior on top of the standard render (e.g.
    # `ProgressBar`, `Gradient`). Returns the render's `RenderedGeometry` (or `nil` when
    # nothing was rendered). Use `next` inside the block to bail out early while
    # still returning the coords.
    # Shared body of `with_inner_coords`/`with_content_coords`: runs the base
    # `base_render` (forwarding *with_children*), bails when nothing rendered, then
    # insets the resulting coordinates by this widget's border — and, when *pad*
    # is true, additionally by the padding — before yielding the interior
    # rectangle `(xi, xl, yi, yl)`. Returns the render's `RenderedGeometry` (or `nil`).
    #
    # The inset is strictly by-value: `ret` is this widget's cached `@lpos`, and
    # `Border#adjust(pos)`/`Padding#adjust(pos)` would shrink it in place, so
    # mutating it would permanently collapse `@lpos` to the interior,
    # under-reporting mouse hit-testing, damage-tracking bounds, and
    # `clear_last_rendered_position` until the next frame. The loose-locals
    # arithmetic used here leaves `@lpos`/`ret` describing the full rect.
    private def with_inset_coords(with_children, pad : Bool, & : (Int32, Int32, Int32, Int32) -> _) : RenderedGeometry?
      ret = base_render with_children
      return unless ret
      xi, xl, yi, yl = ret.xi, ret.xl, ret.yi, ret.yl
      # Effective insets, exactly as `base_render` applies them: `ret` is
      # clamped to a clipping ancestor's viewport, so on a clipped edge only
      # the visible remainder of the border/padding band insets the interior.
      border = style.border
      padding = style.padding
      insets = effective_insets(border, padding, ret)
      ebl, epl = insets.left
      ebt, ept = insets.top
      ebr, epr = insets.right
      ebb, epb = insets.bottom
      xi += pad ? ebl + epl : ebl
      xl -= pad ? ebr + epr : ebr
      yi += pad ? ebt + ept : ebt
      yl -= pad ? ebb + epb : ebb
      yield xi, xl, yi, yl
      ret
    end

    def with_inner_coords(with_children = true, & : (Int32, Int32, Int32, Int32) -> _) : RenderedGeometry?
      with_inset_coords(with_children, false) { |xi, xl, yi, yl| yield xi, xl, yi, yl }
    end

    # Like `with_inner_coords`, but insets the rendered rectangle by the border
    # AND the padding — the interior *content* region, matching the two-step
    # inset `base_render` itself applies (border first, then padding) before laying
    # out content. Yields `(xi, xl, yi, yl)` for a widget that paints its own
    # content straight into the cell buffer on top of the standard render (e.g.
    # `Effect::Direct`). Returns the render's `RenderedGeometry` (or `nil` when nothing was
    # rendered). `with_children` is forwarded to `base_render` so an interior-painting
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
    def self.style_to_attr_flags(style) : Int64
      # TODO support style.* being Procs ?
      # `visible` lives on `Style` proper, not the shared SGR mixin: a `Border`
      # passed here (a widget's four sides share it as the style object) has no
      # `visible?` and is always drawn. `responds_to?` resolves at compile time.
      Attr.flags_of(
        bold: style.bold?, italic: style.italic?, underline: style.underline?,
        blink: style.blink?, reverse: style.reverse?, strike: style.strike?,
        invisible: style.responds_to?(:visible?) && !style.visible?)
    end

    # Packs a precomputed flag word (see `#style_to_attr_flags`) together with
    # *fg*/*bg* into a full attr, applying the same "both unset falls back to
    # the style's own fg/bg" rule as `#style_to_attr`.
    def self.pack_attr(flags : Int64, style, fg = nil, bg = nil) : Int64
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

    # `Style` overload: with no fg/bg override the style already maintains its
    # packed attr incrementally (`Style#packed_attr`), so the whole derivation
    # is a single load — the per-frame path for every widget whose style
    # animates in place.
    def self.style_to_attr(style : ::Crysterm::Style, fg = nil, bg = nil) : Int64
      return style.packed_attr if fg.nil? && bg.nil?
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
    #
    # `AlwaysInline` so the already-resolved case — the common case once a
    # widget has rendered once this frame — folds to a couple of loads and a
    # compare; the resolve arm stays outlined in `#resolve_last_rendered_position`.
    @[AlwaysInline]
    def last_rendered_position? : RenderedGeometry?
      pos = @lpos
      return pos if pos && pos.aleft
      resolve_last_rendered_position
    end

    # The miss arm of `#last_rendered_position?`: resolves `@lpos`'s absolute
    # and inset fields in place from the window's extent.
    private def resolve_last_rendered_position : RenderedGeometry?
      pos = @lpos || return

      # Resolving needs the window's extent; a detached widget with a stale
      # `@lpos` has none — report "no usable rendered position" instead of
      # raising (this is the documented non-raising variant), and mutate
      # nothing so the object isn't left half-resolved.
      scr = window? || return

      pos.aleft = pos.xi
      pos.atop = pos.yi
      pos.aright = scr.awidth - pos.xl
      pos.abottom = scr.aheight - pos.yl
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
    @[AlwaysInline]
    def last_rendered_position : RenderedGeometry
      last_rendered_position? ||
        raise "Widget has no rendered position (never rendered, or fully clipped last frame); use #last_rendered_position? instead"
    end

    # Clears area/position of widget's last render
    def clear_last_rendered_position(*, rendered : Bool = false, force : Bool = false)
      return unless window?
      # Reuse the cached `@lpos` from the previous `base_render` instead of
      # recomputing geometry from scratch — it's still correct even after the
      # caller moved the widget, since `@lpos` holds where it actually painted.
      # Falls back to `coords` only when never rendered. Same
      # `@lpos || coords` idiom as `widget_scrolling.cr`.
      lpos = @lpos || coords(rendered: rendered)
      return unless lpos
      window.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, force: force)
    end

    # Clears the last-rendered rect of *el*'s whole subtree. Explicit recursion,
    # allocation-free. Per-frame callers must filter out `layout_excluded?`
    # chrome, which renders out-of-band with its own live `lpos` (a
    # mutation-time caller like `Widget#insert` clears it too: on a reparent
    # nothing in the subtree is painting at its new place yet, and the chrome
    # refreshes its own `lpos` on the owner's next render).
    protected def clear_subtree_lpos(el : Widget) : Nil
      el.lpos = nil
      el.children.each { |c| clear_subtree_lpos c }
    end

    # Marks this widget's whole subtree layout-suppressed with no rendered rect
    # — the state `Layout#skip_subtree` gives a branch the engines omit this
    # frame (a non-current `Layout::Stack` page): `lpos = nil` so hit-testing
    # can't route clicks/hovers into it, and `layout_suppressed = true` so
    # focus/Tab navigation skips it (`Window`'s `on_screen_here?` tests each
    # widget's OWN flag, so every descendant needs it set, not just the root).
    #
    # Prunes on the subtree invariant "a node with `lpos.nil? &&
    # layout_suppressed?` has its whole subtree in that same state": such a
    # node is already final, so the walk returns without recursing. A hidden
    # page's subtree is thus walked once when it leaves the screen and costs
    # O(1) per frame thereafter, instead of an O(subtree) re-walk on every
    # arrange. The invariant holds because:
    #
    # * `layout_suppressed` is only ever set true here, always together with
    #   `lpos = nil` and always over the whole (non-final) subtree;
    # * a live `lpos` is only (re)acquired in `base_render`, which resolves
    #   against the parent's *rendered* position — impossible under an
    #   ancestor with nil `lpos` — and renders top-down, clearing each
    #   visited widget's own flag on entry, so a re-shown branch is wholly
    #   non-final again by the time a later skip walk meets it;
    # * `Widget#insert` re-establishes the state on a subtree attached under
    #   a suppressed parent at mutation time (see there).
    #
    # (Residual edge: directly `#paint`/`#repaint`-ing a *visible* widget
    # strictly inside a suppressed subtree raises out of `coords` — its parent
    # has no rendered position — but only after `base_render` already cleared
    # that widget's own flag. Code that swallows the exception leaves the
    # widget focus-eligible (nil `lpos`, flag false) until its branch next
    # renders.)
    def suppress_subtree : Nil
      return if @lpos.nil? && layout_suppressed?
      @lpos = nil
      self.layout_suppressed = true
      children.each &.suppress_subtree
    end

    # Clears the last-rendered rects of every non-excluded child subtree — what
    # each of `#base_render`'s "this widget paints nowhere this frame" early
    # returns owes its descendants, or `Window#widget_at` keeps routing
    # clicks/hovers to stale subtree rects. Holds the load-bearing
    # `layout_excluded?` filter (see `#clear_subtree_lpos`) once, so a future
    # fourth early-out cannot silently omit it.
    protected def clear_children_lpos : Nil
      children.each { |c| clear_subtree_lpos c unless c.layout_excluded? }
    end
  end
end
