module Crysterm
  class Widget
    # module Rendering
    include Crystallabs::Helpers::Alias_Methods

    # Per-widget override of the overflow action; `nil` means "inherit". Read
    # through `#overflow`, which falls back to the screen's default when unset,
    # so each widget is independently controllable while a plain widget still
    # follows the screen-wide policy (`Config.screen_overflow`). Set via
    # `#overflow=` (accepts an `Overflow`, a shorthand, or `nil` to re-inherit).
    @overflow : Overflow? = nil

    # What action to take when this widget overflows its parent's rectangle.
    # Returns the per-widget override if one is set, otherwise the screen's
    # `#overflow` default (or `Overflow::Ignore` for a screen-less widget).
    def overflow : Overflow
      @overflow || screen?.try(&.overflow) || Overflow::Ignore
    end

    # The raw per-widget override (`nil` = inheriting the screen default).
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

    # The layout engine that arranges this widget's children, or nil for manual
    # placement — children positioning themselves from their own coordinates
    # (the historical default). This mirrors Qt, where `QWidget::layout()` is
    # null until one is installed. When nil, `#_render` falls back to the shared
    # `Layout::Manual`. Assign an engine (`Layout::HBox`, `Layout::Border`, …)
    # to have it arrange the children.
    property layout : Crysterm::Layout? = nil

    # Optional per-child hint read by this widget's *parent's* layout engine
    # (a Border region, a Grid cell+span, a flex grow factor). The concrete type
    # is defined by the engine; see `Crysterm::Layout::Hint`.
    property layout_hint : Crysterm::Layout::Hint? = nil

    # Rendition and rendering

    # The below methods are a bit confusing: basically
    # whenever Box.render is called `lpos` gets set on
    # the element, an object containing the rendered
    # coordinates. Since these don't update if the
    # element is moved somehow, they're unreliable in
    # that situation. However, if we can guarantee that
    # lpos is good and up to date, it can be more
    # accurate than the calculated positions below.
    # In this case, if the element is being rendered,
    # it's guaranteed that the parent will have been
    # rendered first, in which case we can use the
    # parent's lpos instead of recalculating its
    # position (since that might be wrong because
    # it doesn't handle content shrinkage).

    property items = [] of Widget::Box

    # True only while this widget is being rendered as a layer root into its own
    # `Plane` (see `Screen#composite_planes`). Its overall translucency then comes
    # from the plane's opacity, so its render-time alpha self-blend is suppressed.
    property compositing = false

    # Here be dragons

    # Resolves the `Style` a *child* should render with. The base just returns
    # the child's own style; container widgets that style their children (e.g.
    # `Widget::List` highlighting the selected row) override this. Called from
    # `#_render` on the child's parent, so a child renders with whatever style
    # its parent dictates — no `is_a?`/flag check at the call site.
    def render_style_for(item : Widget) : Style
      item.style
    end

    # Renders all child elements into the output buffer.
    # ameba:disable Metrics/CyclomaticComplexity
    def _render(with_children = true)
      emit Crysterm::Event::PreRender

      # Let the parent dictate this widget's render style (a list highlights its
      # selected row, etc.); for an ordinary parent `render_style_for` just hands
      # back our own style. `own_style` is captured so the `default_attr` below can
      # tell when the render style IS the widget's own (the overwhelmingly common
      # case) and reuse the `sattr` already computed by `process_content`.
      own_style = self.style
      style = parent.try(&.render_style_for(self)) || own_style

      # Keep any border label glued to the (possibly CSS-resolved) top inset.
      # Must run before the label child renders, hence here at the frame's start.
      sync_label_position

      # The parent has already rendered this frame (children render after their
      # parent), so `awidth(true)` is an O(1) read of the parent's cached `lpos`.
      # Hand it to `process_content` so its per-frame width resolution doesn't
      # walk the ancestor chain with `awidth(false)` (O(depth)) just to compute
      # the content column width. `_get_coords` needs the very same value (its
      # first step is `awidth(get)`), and nothing between here and there changes
      # this widget's width, so resolve it once and pass it to both instead of
      # computing it twice per widget per frame.
      aw = awidth(true)
      process_content awidth_hint: aw

      # Pass the existing `@lpos` so `_get_coords` updates it in place instead of
      # allocating a fresh `LPos` for this widget on every frame (per-frame heap
      # garbage → GC jitter). On the first render (or after a frame that produced
      # no coords) `@lpos` is nil and `_get_coords` allocates as before.
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

      # `screen` is `screen?.not_nil!`, which walks the parent chain on every
      # call; bind it once. `full_unicode?` (which also walks the parent chain
      # via `screen?`) and `style.alpha?`/`style.padding` are all constant for
      # the whole render, so hoist them here instead of re-evaluating them in
      # the per-cell loops below. Mirrors how `Screen#draw` binds `fu` once.
      scr = screen
      # Start/keep/stop any CSS `@keyframes` animation bound to this widget
      # (cheap no-op unless an `animation` is declared).
      ensure_css_animation

      lines = scr.lines
      fu = scr.full_unicode?
      # A layer root's alpha is applied as its plane's opacity at composite time,
      # so suppress the render-time self-blend while it paints into the plane.
      style_alpha = @compositing ? nil : style.alpha?
      padding = style.padding
      xi = coords.xi
      xl = coords.xl
      yi = coords.yi
      yl = coords.yl
      # x
      # y
      # cell
      # attr
      # ch
      # Log.trace { lines.inspect }
      # `#pcontent` materializes the printable string if a deferred append left it
      # stale (nil), caching it back into `@_pcontent`. Once per frame after a
      # change — not once per appended line.
      pcontent = self.pcontent
      # Reuse the cached codepoint index unless `@_pcontent` was reparsed into a
      # fresh `String` (identity check). Rebuilding it every frame would re-scan
      # the content and, for non-ASCII text, re-materialize a `chars` array —
      # per-frame heap garbage that causes GC-induced frame jitter.
      content = @_content_index
      unless content && content.built_from?(pcontent)
        content = StringIndex.new pcontent
        @_content_index = content
      end
      ci = @_clines.ci[coords.base]? || 0 # XXX Is it ok that array lookup can be nil? and defaulting to 0?
      # battr
      # default_attr
      # c
      # visible
      # i
      bch = style.fill_char

      # D O:
      # Clip content if it's off the edge of the screen
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

      # `process_content` (called above) already computed `sattr(self.style)` and
      # cached it in `@_parse_attr_default`. When the render style IS the widget's
      # own style (true for everything except a parent that substitutes one, e.g. a
      # `List` highlighting its selected row), that cached value equals what
      # `sattr style` would recompute, so reuse it instead of repacking the same
      # eight style fields a second time per widget per frame. The `same?` identity
      # check is cheap; the `|| sattr(style)` is a defensive fallback (the cache is
      # always populated here, since `process_content` ran with a non-nil screen).
      default_attr = (style.same?(own_style) ? @_parse_attr_default : nil) || sattr(style)
      attr = default_attr

      # If we're in a scrollable text box, check to
      # see which attributes this line starts with.
      if ci > 0
        attr = @_clines.attr.try(&.[Math.min(coords.base, @_clines.size - 1)]?) || 0_i64
      end

      style.border.try do |border|
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl
      end

      # If we have padding/valign, that means the
      # content-drawing loop will skip a few cells/lines.
      # To deal with this, we can just fill the whole thing
      # ahead of time. This could be optimized.
      if padding.any? || !@align.top?
        if alpha = style_alpha
          (Math.max(yi, 0)...yl).each do |y|
            line = lines[y]?
            unless line
              break
            end
            (Math.max(xi, 0)...xl).each do |x|
              cell = line[x]?
              unless cell
                break
              end
              cell.attr = Colors.blend(attr, cell.attr, alpha: alpha)
              # D O:
              # cell.char = bch
              line.mark_dirty x
            end
          end
        else
          scr.fill_region(default_attr, bch, xi, xl, yi, yl)
        end
      end

      # Background image (CSS `background-image`): paint the internal `Media`
      # layer behind the content. Done *before* the content loop so text draws on
      # top; the layer is excluded from the normal child pass and rendered here
      # instead (see `widget_background.cr`). A Kitty layer is cell-neutral; a
      # cell-grid (`Media::Cells`) layer paints the buffer, so `bg_cells` then
      # tells the content loop to leave its empty cells showing the image.
      update_background_media
      bg_cells = background_paints_cells?

      p = padding
      xi, xl, yi, yl = p.adjust xi, xl, yi, yl

      # Reserve the bottom row(s) for a shown horizontal scroll bar so content
      # never paints under it (the row stays `fixed` for the bar to draw into).
      #
      # All the scroll-bar machinery (`hscrollbar_rows`, `update_scrollbar_widget`,
      # and the matching `yl += hscrollbar_rows` restore below) only ever does
      # anything when this widget can scroll — `show_*scrollbar?` short-circuits to
      # `false` unless `scrollable?`, regardless of policy. A non-scrollable widget
      # that has never shown a bar (`@*scrollbar_widget` both nil) therefore has
      # nothing to compute or reconcile, so skip the whole block: it turns three
      # `show_*scrollbar?` method-chain calls per widget per frame into zero for
      # the overwhelmingly common non-scrollable case (every plain Box/Label). The
      # `@*scrollbar_widget` guard still runs the reconcile for a widget that *was*
      # scrollable and showed a bar, so a bar is still hidden when scrolling is
      # turned off. `hsr` is computed once and reused by the restore below.
      may_scroll = scrollable? || !@scrollbar_widget.nil? || !@horizontal_scrollbar_widget.nil?
      hsr = may_scroll ? hscrollbar_rows : 0
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
      # its content keeps the default foreground (only bg/flags follow inline SGR
      # changes). This is invariant for the whole render, so resolve it once here
      # instead of re-walking the parent chain — and, for a multi-select list,
      # re-running the O(n) `item_selected?` scan — on every SGR escape of every
      # cell with colored content.
      keep_selected_fg = parent.try do |parent2|
        parent2._is_list && parent2.interactive? && parent2.item_selected?(self) # XXX && parent2.invert_selected
      end || false

      # Draw the content and background.
      # yi.step to: yl-1 do |y|
      (yi...yl).each do |y|
        line = lines[y]?
        unless line
          if y >= scr.aheight || yl < ibottom
            break
          else
            next
          end
        end
        # TODO - make cell exist only if there's something to be drawn there?
        x = xi - 1
        while x < xl - 1
          x += 1
          cell = line[x]?
          unless cell
            if x >= scr.awidth || xl < iright
              break
            else
              next
            end
          end

          ch = content[ci]? || bch
          # Log.trace { ci }
          ci += 1

          # D O:
          # if (!content[ci] && !coords._content_end)
          #   coords._content_end = { x: x - xi, y: y - yi }
          # end

          # Handle escape codes.
          while ch == '\e'
            # Recognize the SGR sequence (`\e[[\d;]*m`, i.e. `SGR_REGEX`) in place
            # by scanning codepoints directly, instead of `SGR_REGEX.match`, which
            # allocated a `Regex::MatchData` plus a matched-substring `String`
            # (`c[0]`) on EVERY escape of every cell with colored content. `ci - 1`
            # is the `\e` we just consumed; `ci` should be the `[`, then a run of
            # digits/`;`, then the terminating `m`. SGR is pure ASCII.
            if content[ci]? == '[' && (m = sgr_terminator(content, ci + 1))
              # `m` is the codepoint index of the trailing 'm'. Parse the params
              # straight out of `content` between the `\e` and the 'm' — no
              # substring. Then advance just past the 'm' (matching the old
              # `ci += c[0].size - 1`, where the match length is `m - (ci-1) + 1`).
              attr = scr.attr2code(content, ci - 1, m, attr, default_attr)
              ci = m + 1
              # Ignore foreground changes for selected items (keep the default
              # foreground while letting the rest of the attr change). The
              # selection test is hoisted to `keep_selected_fg` above.
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
            # If we're on the first cell and we find a newline and the last cell
            # of the last line was not a newline, let's just treat this like the
            # newline was already "counted".
            if (x == xi) && (y != yi) && (content[ci - 2]? != '\n')
              x -= 1
              next
            end
            # We could use fill_region here, name the
            # outer loop, and continue to it instead.
            ch = bch
            # A buffer-image background owns the rest of this line: leave its
            # cells showing the painted image instead of clearing them.
            unless bg_cells
              while x < xl
                cell = line[x]?
                if !cell
                  break
                end
                if alpha = style_alpha
                  cell.attr = Colors.blend(attr, cell.attr, alpha: alpha)
                  if content[ci - 1]?
                    cell.char = ch
                  end
                  line.mark_dirty x
                else
                  if cell != {attr, ch}
                    cell.attr = attr
                    cell.char = ch
                    line.mark_dirty x
                  end
                end
                x += 1
              end
            end

            # It was a newline; we've filled the row to the end, we
            # can move to the next row.
            next
          end

          # Whether this cell maps to a real content codepoint (vs. the fill
          # char `bch` past the end of content).
          has_content = !content[ci - 1]?.nil?

          # A buffer-image background (`Media::Cells`) has painted this content
          # box; leave an empty (no-glyph) cell showing the image rather than
          # overwriting it with the widget's fill. Text cells still draw on top.
          next if bg_cells && !has_content

          # Grapheme handling (full_unicode): lay multi-codepoint clusters (emoji
          # ZWJ sequences, flags, base+combining marks) into one cell + a wide
          # continuation cell. Legacy keeps one codepoint per cell.
          #
          # Fast path: `needs_cluster?` cheaply rules out the lone codepoint that
          # the overwhelming majority of cells are, so the common case takes the
          # `Char` width overload and the `cell.char = ch` write below — NO
          # `String` allocation, the same cost as legacy rendering. The
          # (allocating) `extend_grapheme` runs only when a cell genuinely is a
          # cluster, gated by `is_cluster`.
          grapheme = ""
          cell_width = 1
          is_cluster = false
          if fu && has_content
            if needs_cluster? ch, content[ci]?
              # Costly path — this cell really is a multi-codepoint cluster.
              #
              # The `String` here is essentially unavoidable: a cluster has no
              # single-`Char` representation, and it must be materialized to store
              # in the row's `@graphemes` overlay AND to emit as one unit at draw
              # time. It cannot be rewritten away without changing the overlay's
              # storage type. It is, however, *rare* (only true clusters reach
              # here — plain text never does), so the per-frame allocation count
              # is bounded by the handful of cluster cells on screen, not the cell
              # count. (A further micro-optimization — comparing an unchanged
              # cluster against the content codepoints to skip even this
              # allocation on steady-state frames — was judged not worth the
              # complexity given how few cells are clusters.)
              grapheme, ci = extend_grapheme(content, ci, ch)
              cell_width = ::Crysterm::Unicode.width grapheme
              is_cluster = true
              if cell_width == 0
                # Zero-width cluster (e.g. a leading combining mark): merge into
                # the previous cell rather than consuming one.
                if x > xi && (prev = line[x - 1]?)
                  prev.grapheme = prev.grapheme + grapheme
                  line.mark_dirty(x - 1)
                end
                x -= 1
                next
              end
            else
              # Lone codepoint: width straight from the `Char`, stored as a char.
              cell_width = ::Crysterm::Unicode.width ch
            end
          end

          unless style.fill?
            next
          end

          if alpha = style_alpha
            cell.attr = Colors.blend(attr, cell.attr, alpha: alpha)
            if has_content
              is_cluster ? (cell.grapheme = grapheme) : (cell.char = ch)
            end
            line.mark_dirty x
          elsif is_cluster
            if cell.attr != attr || !cell.grapheme_eq?(grapheme)
              cell.attr = attr
              cell.grapheme = grapheme
              line.mark_dirty x
            end
          else
            if cell != {attr, ch}
              cell.attr = attr
              cell.char = ch
              line.mark_dirty x
            end
          end

          # Wide cell (a 2-column cluster, or a wide lone codepoint like CJK):
          # claim the following cell as its continuation so the cell grid stays
          # 1 cell == 1 terminal column.
          if fu && cell_width == 2 && (x + 1 < xl) && (nxt = line[x + 1]?)
            nxt.attr = attr
            nxt.continuation!
            line.mark_dirty(x + 1)
            x += 1
          end
        end
      end

      # Scrollbar: a real `Widget::ScrollBar` child — created lazily, fixed at the
      # right edge, and bound to this widget — renders and drives it (so it is a
      # styleable, interactive, compositable widget rather than an inline glyph).
      # See `#update_scrollbar_widget`. It renders below via `render_children`.
      # Skipped entirely for a never-scrollable widget (see `may_scroll` above).
      update_scrollbar_widget if may_scroll

      style.border.try do |border|
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl, -1
      end

      p = padding
      xi, xl, yi, yl = p.adjust xi, xl, yi, yl, -1

      # Add back the row(s) reserved for a shown horizontal scroll bar (subtracted
      # at the content stage above). The bar occupies the last *interior* row; the
      # border must still be drawn at the widget's true bottom edge. Without this
      # restore `yl` stays one row short, so the bottom border paints over the bar
      # row and the real bottom row is left frameless. Reuses `hsr` from above so
      # `hscrollbar_rows` (and its `show_horizontal_scrollbar?` chain) is computed
      # at most once per render instead of twice.
      yl += hsr

      # Draw the border.
      style.border.try do |border|
        # A border with all sides 0 is "no border": nothing to draw.
        next unless border.any?

        # Per-side attributes, so `border-top-color`/`border-left-color`/... can
        # differ. Each falls back to the whole-border color when unset. The border
        # background falls back to the widget's own background (not the terminal
        # default), so a themed widget's frame sits on the same surface as its
        # interior instead of punching a dark hole around it (e.g. a light-themed
        # menu's border row/columns).
        border_bg = border.bg || style.bg
        top_attr = sattr border, border.top_fg, border_bg
        bottom_attr = sattr border, border.bottom_fg, border_bg
        left_attr = sattr border, border.left_fg, border_bg
        right_attr = sattr border, border.right_fg, border_bg

        # The line-drawing glyph set depends only on `border.type`, so resolve it
        # once here instead of re-dispatching it per cell inside `border_char`.
        glyphs = border.type.line_glyphs

        # `{yi, yl - 1}` is a stack-allocated tuple, not a heap `Array`, so the
        # top/bottom row pair is iterated without per-frame allocation.
        {yi, yl - 1}.each do |y|
          line = lines[y]?
          next if y == -1 || !line

          top_row = y == yi
          # When this end row is clipped offscreen (`no_top?`/`no_bottom?`), skip
          # it outright, exactly as before — its border row isn't present here.
          next if top_row ? coords.no_top? : coords.no_bottom?

          # Whether this row's *horizontal* border is actually present. A 0-height
          # top/bottom border was not expanded into its own row (yi/yl-1 still sit
          # on content), so the span between the corners stays content. But a
          # left/right border still runs *vertically* through this row's end
          # cells, so we keep drawing just those — otherwise a partial border
          # (e.g. a docked pane's single content-facing edge) is clipped at the
          # corners, leaving the divider short by its top and bottom cells.
          draw_h = top_row ? border.top > 0 : border.bottom > 0

          # The corners live on the top/bottom rows, so they take that side's
          # color (or the vertical side's color when there's no horizontal one).
          h_attr = top_row ? top_attr : bottom_attr

          (xi...xl).each do |x|
            next if coords.no_left? && x == xi
            next if coords.no_right? && x == xl - 1

            on_left = x == xi && border.left > 0
            on_right = x == xl - 1 && border.right > 0
            # Without a horizontal border on this row, draw only the vertical
            # sides crossing it (its end cells); keep the content in between.
            next unless draw_h || on_left || on_right

            cell = line[x]?
            next unless cell

            ch = border_char(border, glyphs, x, xi, xl, y, yi, yl, default_attr)
            battr = draw_h ? h_attr : (on_left ? left_attr : right_attr)

            if cell != {battr, ch}
              cell.attr = battr
              cell.char = ch
              line.mark_dirty x
            end
          end
        end

        (yi + 1...yl - 1).each do |y|
          line = lines[y]?
          next unless line

          # `{xi, xl - 1}` is a stack-allocated tuple, replacing the heap
          # `Array(Int32)` literal that was otherwise allocated on every interior
          # border row, every frame, for every bordered widget.
          {xi, xl - 1}.each do |x|
            # A 0-width left/right border was not expanded into its own column
            # (xi/xl-1 still sit on the content), so skip it like a
            # `no_left?`/`no_right?` clip instead of overwriting text.
            next if border.left == 0 && x == xi
            next if border.right == 0 && x == xl - 1

            cell = line[x]?
            next unless cell

            ch = border_char(border, glyphs, x, xi, xl, y, yi, yl, default_attr)

            battr = x == xi ? left_attr : right_attr

            if cell != {battr, ch}
              cell.attr = battr
              cell.char = ch
              line.mark_dirty x
            end
          end
        end
      end

      # Shadow. Each side blends a band of cells toward black; the four blocks
      # share one loop (`Screen#blend_region`) and differ only in their bounds.
      # The exact (sometimes unclamped) bounds — including the `Math.max(.,0)`
      # clamps that only some sides applied — are reproduced here so behavior is
      # unchanged.
      if (s = style.shadow) && s.any?
        if s.left?
          i = (yi - s.top) + (s.bottom? && !s.top? && !s.right? ? s.bottom : 0)
          l = s.bottom? ? yl + s.bottom : yl - (s.top? && !s.bottom? ? s.top : 0)
          scr.blend_region s.alpha, xi - s.left, xi, Math.max(i, 0), l
        end

        if s.top?
          l = s.right? ? xl + s.right : (s.left? ? xl - s.left : xl)
          scr.blend_region s.alpha, Math.max(xi, 0), l, yi - s.top, yi
        end

        if s.right?
          i = (s.top? || s.left?) ? yi : yi + s.bottom
          l = s.bottom? ? yl + s.bottom : yl
          scr.blend_region s.alpha, xl, xl + s.right, Math.max(i, 0), l
        end

        if s.bottom?
          i = s.right? ? xi + (s.left? ? 0 : s.right) : xi
          l = xl - (s.left? && !s.top? && !s.right? ? s.left : 0)
          scr.blend_region s.alpha, Math.max(i, 0), l, yl, yl + s.bottom
        end
      end

      # Tint: a colored overlay across this widget's whole box, toward
      # `style.tint` by its strength. Applied before children (like `style.alpha`)
      # so each widget tints only its own cells; animatable via `Widget#tint_to`.
      if t = style.tint?
        color, ta = t
        scr.tint_region ta, color, xi, xl, yi, yl
      end

      if with_children
        # The installed layout engine positions and renders the children; with
        # none, the shared `Layout::Manual` renders each at its own coordinates.
        (@layout || Crysterm::Layout::Manual::DEFAULT).render_children self
      end

      emit Crysterm::Event::Rendered # , coords

      coords
    end

    # Registers, on the screen, the rows on which this widget emits horizontal
    # line-drawing characters, so the screen's docking pass (`Screen#_dock`)
    # can join them with crossing characters from neighboring widgets. See
    # `Crysterm::Docking`.
    #
    # Only rows bearing *horizontal* segments need to be registered: a vertical
    # segment is docked whenever a horizontal stop from some other widget
    # crosses it. The base implementation registers the top and bottom rows of
    # an actual line-type border. Widgets that draw lines by other means (e.g.
    # `Widget::Line`) override this to register their own rows.
    def register_dock_stops(coords)
      style.border.try do |border|
        if border.any? && border.type.line?
          # A widget rendering into a compositing plane (an overlay) registers on
          # the *plane* stops, docked against the plane's own buffer — so overlay
          # borders join one another but not the base content they float over. A
          # base-layer widget registers on the screen stops as before.
          stops = @compositing ? screen._plane_dock_stops : screen._dock_stops
          stops[coords.yi] = true
          stops[coords.yl - 1] = true
        end
      end
    end

    # Re-joins the line-drawing characters on the given screen *rows* into
    # seamless junctions (`├ ┤ ┬ ┼` …), reusing the same `Docking` component the
    # screen uses for `dock_borders` — but on demand, for one widget, regardless
    # of that global setting. Lets a widget connect interior line art (e.g. a
    # `Menu`'s separator rules) to its own border. No-op when detached or given
    # no rows.
    #
    # *contrast* defaults to `DockContrast::Ignore` (each cell keeps its own
    # color, only the joining glyph changes) rather than the screen's global
    # setting — the latter (`Blend`) diffuses the junction's blended color along
    # the whole run, muddying e.g. a separator's divider color. Pass another
    # value to opt into blending.
    protected def dock_rows(rows : Enumerable(Int32), contrast : DockContrast = DockContrast::Ignore) : Nil
      scr = screen? || return
      stops = {} of Int32 => Bool
      rows.each { |y| stops[y] = true }
      return if stops.empty?
      Docking.dock scr.lines, stops, scr.awidth, contrast
    end

    @[AlwaysInline]
    # ameba:disable Metrics/CyclomaticComplexity
    def border_char(border, g, x, xi, xl, y, yi, yl, default_attr)
      if border.type.line_family?
        # Per-type glyph set (solid/dashed/dotted/double), resolved once by the
        # caller. A corner cell falls back to the straight run glyph when one of
        # its two sides has 0 width.
        ch = case {x, y}
             when {xi, yi}         then border.left > 0 && border.top > 0 ? g[:tl] : (border.left == 0 && border.top > 0 ? g[:h] : g[:v])
             when {xl - 1, yi}     then border.right > 0 && border.top > 0 ? g[:tr] : (border.right == 0 && border.top > 0 ? g[:h] : g[:v])
             when {xi, yl - 1}     then border.left > 0 && border.bottom > 0 ? g[:bl] : (border.left == 0 && border.bottom > 0 ? g[:h] : g[:v])
             when {xl - 1, yl - 1} then border.right > 0 && border.bottom > 0 ? g[:br] : (border.right == 0 && border.bottom > 0 ? g[:h] : g[:v])
             else
               if (x == xi || x == xl - 1) && (y > yi && y < yl - 1)
                 g[:v]
               else
                 g[:h]
               end
             end
      elsif border.type.bg?
        # Pick the char by position so a `Bg` border can use distinct glyphs for
        # its horizontal sides, vertical sides, and the corners where they join
        # (see `Border#horizontal_char`/`#vertical_char`/`#corner_char`).
        on_top = y == yi && border.top > 0
        on_bottom = y == yl - 1 && border.bottom > 0
        on_left = x == xi && border.left > 0
        on_right = x == xl - 1 && border.right > 0
        ch = if (on_top || on_bottom) && (on_left || on_right)
               # Cell where a horizontal and a vertical side actually meet.
               border.corner_char
             elsif on_top || on_bottom
               border.horizontal_char
             else
               border.vertical_char
             end
      end

      # Note: cells on a 0-width/height side are no longer reached here — the
      # drawing loops in `_render` skip them outright (like `no_top?`/`no_left?`),
      # so there is nothing to blank out.

      ch || ' ' # Just a failsafe
    end

    # Returns the codepoint index of the `m` terminating an SGR sequence whose
    # parameter run starts at `i` (the first codepoint after `\e[`), or `nil` if
    # the run is not `[\d;]* m` — i.e. exactly when `SGR_REGEX` would fail to
    # match. Lets `_render` recognize SGR sequences without allocating a
    # `Regex::MatchData`/substring per escape.
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
    # nothing was rendered) so callers can simply `with_inner_coords { ... }` as
    # the body of their `#render`. Use `next` inside the block to bail out early
    # while still returning the coords.
    def with_inner_coords(& : (Int32, Int32, Int32, Int32) -> _) : LPos?
      ret = _render
      return unless ret
      style.border.try &.adjust(ret)
      yield ret.xi, ret.xl, ret.yi, ret.yl
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

      # `fg`/`bg` are already native colors (a `0xRRGGBB` int, `-1` for the
      # terminal default, or `nil` for "unset" — which also maps to the default).
      # `Attr.pack_color` maps that into a packed color field. Because colors are
      # stored natively there is no per-frame string parse here anymore.
      Attr.pack(flags, Attr.pack_color(fg || -1), Attr.pack_color(bg || -1))
    end

    def sattr(style, fg = nil, bg = nil)
      self.class.sattr style, fg, bg
    end

    def last_rendered_position
      @lpos.try do |pos|
        # If already cached/computed, return that:
        return pos if pos.aleft

        # Otherwise go compute:
        pos.aleft = pos.xi
        pos.atop = pos.yi
        pos.aright = screen.awidth - pos.xl
        pos.abottom = screen.aheight - pos.yl
        pos.awidth = pos.xl - pos.xi
        pos.aheight = pos.yl - pos.yi

        # And these are important to carry over:
        pos.ileft = ileft
        pos.itop = itop
        pos.iright = iright
        pos.ibottom = ibottom

        return pos
      end

      raise "Shouldn't happen"
      # This is here just to prevent nil in return type. If this
      # can realistically happen, use something like:
      # LPos.new
      # (And possibly make sure to carry over the i* values like above)
    end

    # Clears area/position of widget's last render
    def clear_last_rendered_position(get = false, override = false)
      return unless screen?
      # Clear the rectangle this widget was *last painted* into, which is exactly
      # the cached `@lpos` from its previous `_render` — so reuse it instead of
      # recomputing the geometry from scratch (`awidth`/`aleft`/`atop` plus the
      # ancestor-clip walk) every call. This is the right region even after the
      # caller has changed `left`/`top` to move the widget, since `@lpos` still
      # holds where it actually was. Falls back to `_get_coords` only when the
      # widget has never rendered (`@lpos` nil) — then there is no stale paint to
      # erase, but the old computed-position behavior is preserved. (Same
      # `@lpos || _get_coords` idiom as `widget_scrolling.cr`.)
      lpos = @lpos || _get_coords(get)
      return unless lpos
      screen.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, override)
    end
  end
end
