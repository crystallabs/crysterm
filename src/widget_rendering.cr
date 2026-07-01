module Crysterm
  class Widget
    # module Rendering
    include Crystallabs::Helpers::Alias_Methods

    # Per-widget override of the overflow action; `nil` = inherit. Read through
    # `#overflow`, which falls back to the window default (`Config.window_overflow`)
    # when unset. Set via `#overflow=` (an `Overflow`, a shorthand, or `nil`).
    @overflow : Overflow? = nil

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
        attr = @_clines.attr.try(&.[Math.min(coords.base, @_clines.size - 1)]?) || 0_i64
      end

      style.border.try do |border|
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl
      end

      # Padding/valign make the content loop skip some cells/lines, so fill the
      # whole box ahead of time.
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
              # cell.char = bch
              line.mark_dirty x
            end
          end
        else
          scr.fill_region(default_attr, bch, xi, xl, yi, yl)
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

      # Reserve the bottom row(s) for a shown horizontal scroll bar so content
      # never paints under it. `may_scroll` skips this for the common
      # non-scrollable case, but still reconciles a widget that *was* scrollable
      # so its bar gets hidden when scrolling is turned off. `hsr` is reused by
      # the restore below.
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
      # content keeps the default foreground (only bg/flags follow inline SGR).
      # Resolved once here instead of re-walking the parent chain per SGR escape.
      keep_selected_fg = parent.try do |parent2|
        parent2._is_list && parent2.interactive? && parent2.item_selected?(self) # XXX && parent2.invert_selected
      end || false

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
            # cells showing the painted image instead of clearing them.
            unless bg_cells
              while x < xl
                # Off-window columns (`x < 0`) advance to keep the fill aligned
                # but are never fetched/painted (negative-index wrap).
                fcell = x >= 0 ? line[x]? : nil
                break if x >= 0 && fcell.nil?
                if draw_row && (fc = fcell)
                  if alpha = style_alpha
                    fc.attr = Colors.blend(attr, fc.attr, alpha: alpha)
                    if content[ci - 1]?
                      fc.char = ch
                    end
                    line.mark_dirty x
                  else
                    fc.set_if_changed(attr, ch)
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
                # the previous cell rather than consuming one.
                if draw_row && x > xi && x - 1 >= 0 && (prev = line[x - 1]?)
                  prev.grapheme = prev.grapheme + grapheme
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

          unless style.fill?
            next
          end

          if t = target
            if alpha = style_alpha
              t.attr = Colors.blend(attr, t.attr, alpha: alpha)
              if has_content
                is_cluster ? (t.grapheme = grapheme) : (t.char = ch)
              end
              line.mark_dirty x
            elsif is_cluster
              if t.attr != attr || !t.grapheme_eq?(grapheme)
                t.attr = attr
                t.grapheme = grapheme
                line.mark_dirty x
              end
            else
              t.set_if_changed(attr, ch)
            end
          end

          # Wide cell (2-column cluster or wide codepoint like CJK): claim the
          # next cell as its continuation so 1 cell == 1 terminal column. The
          # claim happens even off-window to stay in step; only the write is gated.
          if fu && cell_width == 2 && (x + 1 < xl) && (nxt = line[x + 1]?)
            if draw_row && x + 1 >= 0
              nxt.attr = attr
              nxt.continuation!
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

        # Per-side attributes so `border-top-color` etc. can differ, each falling
        # back to the whole-border color. Border bg falls back to the widget's
        # own bg (not the terminal default), so a themed frame sits flush with
        # its interior.
        border_bg = border.bg || style.bg
        top_attr = sattr border, border.top_fg, border_bg
        bottom_attr = sattr border, border.bottom_fg, border_bg
        left_attr = sattr border, border.left_fg, border_bg
        right_attr = sattr border, border.right_fg, border_bg

        # Resolved once here instead of re-dispatching per cell inside `border_char`.
        glyphs = border.type.line_glyphs

        # `{yi, yl - 1}` is a stack tuple, so the top/bottom pair iterates
        # without allocation.
        {yi, yl - 1}.each do |y|
          line = lines[y]?
          # `y < 0` (not just `== -1`): a widget clipped off the TOP can have
          # `yi` several rows above 0, and `lines[y]?` wraps a negative index to
          # the bottom rows — drawing a border there would corrupt the window.
          next if y < 0 || !line

          top_row = y == yi
          # Skip if this end row is clipped offscreen — its border row isn't
          # present here.
          next if top_row ? coords.no_top? : coords.no_bottom?

          # Whether this row's *horizontal* border is present. A 0-height
          # top/bottom border leaves the span between corners as content, but a
          # left/right border still runs through the end cells, so draw just
          # those.
          draw_h = top_row ? border.top > 0 : border.bottom > 0

          # Corners take the top/bottom side's color (or the vertical side's
          # color when there's no horizontal one).
          h_attr = top_row ? top_attr : bottom_attr

          (xi...xl).each do |x|
            next if x < 0 # off the left edge (negative index would wrap)
            next if coords.no_left? && x == xi
            next if coords.no_right? && x == xl - 1

            on_left = x == xi && border.left > 0
            on_right = x == xl - 1 && border.right > 0
            # Without a horizontal border on this row, draw only the vertical
            # sides crossing it; keep content in between.
            next unless draw_h || on_left || on_right

            cell = line[x]?
            next unless cell

            ch = border_char(border, glyphs, x, xi, xl, y, yi, yl, default_attr)
            battr = draw_h ? h_attr : (on_left ? left_attr : right_attr)

            cell.set_if_changed(battr, ch)
          end
        end

        (yi + 1...yl - 1).each do |y|
          next if y < 0 # off the top edge (negative index would wrap)
          line = lines[y]?
          next unless line

          # `{xi, xl - 1}` is a stack tuple, avoiding a heap `Array` literal per
          # interior border row.
          {xi, xl - 1}.each do |x|
            next if x < 0 # off the left edge (negative index would wrap)
            # A 0-width left/right border isn't its own column; skip instead of
            # overwriting text.
            next if border.left == 0 && x == xi
            next if border.right == 0 && x == xl - 1

            cell = line[x]?
            next unless cell

            ch = border_char(border, glyphs, x, xi, xl, y, yi, yl, default_attr)

            battr = x == xi ? left_attr : right_attr

            cell.set_if_changed(battr, ch)
          end
        end
      end

      # Shadow: each side blends a band of cells toward black via
      # `Window#blend_region`, differing only in bounds.
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
        # caller. A corner cell falls back to the straight glyph when one of its
        # two sides has 0 width.
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
        # horizontal sides, vertical sides, and corners (see
        # `Border#horizontal_char`/`#vertical_char`/`#corner_char`).
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

      # Cells on a 0-width/height side are no longer reached here — `_render`'s
      # drawing loops skip them outright.

      ch || ' ' # failsafe
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
      # in place, so the old `style.border.try &.adjust(ret)` permanently
      # collapsed `@lpos` to the interior, under-reporting mouse hit-testing,
      # damage-tracking bounds, and `clear_last_rendered_position` until the
      # next frame. Use the allocation-free by-value overload instead, leaving
      # `@lpos`/`ret` describing the full widget rect.
      xi, xl, yi, yl = ret.xi, ret.xl, ret.yi, ret.yl
      if border = style.border
        xi, xl, yi, yl = border.adjust xi, xl, yi, yl
      end
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
