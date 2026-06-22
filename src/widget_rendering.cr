module Crysterm
  class Widget
    # module Rendering
    include Crystallabs::Helpers::Alias_Methods

    # What action to take when widget is overflowing parent's rectangle?
    Crystallabs::Helpers::Enums.enum_property overflow : Overflow = Overflow::Ignore

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

    # Here be dragons

    # Renders all child elements into the output buffer.
    def _render(with_children = true)
      emit Crysterm::Event::PreRender

      # XXX TODO Is this a hack in Crysterm? It allows elements within lists to be styled as appropriate.
      style = self.style
      parent.try do |parent2|
        if parent2._is_list && parent2.is_a? Widget::List
          style = parent2.render_style_for(self)
        end
      end

      process_content

      # Pass the existing `@lpos` so `_get_coords` updates it in place instead of
      # allocating a fresh `LPos` for this widget on every frame (per-frame heap
      # garbage → GC jitter). On the first render (or after a frame that produced
      # no coords) `@lpos` is nil and `_get_coords` allocates as before.
      coords = _get_coords(true, into: @lpos)
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

      lines = screen.lines
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
      pcontent = @_pcontent || ""
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
      bch = style.char

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

      default_attr = sattr style
      attr = default_attr

      # If we're in a scrollable text box, check to
      # see which attributes this line starts with.
      if ci > 0
        attr = @_clines.attr.try(&.[Math.min(coords.base, @_clines.size - 1)]?) || 0_i64
      end

      # TODO See if these 4 values could be packed somehow to just replace individual
      # settings with the usual: style.border.try &.adjust(pos) ?
      style.border.try do |border|
        xi += border.left
        xl -= border.right
        yi += border.top
        yl -= border.bottom
      end

      # If we have padding/valign, that means the
      # content-drawing loop will skip a few cells/lines.
      # To deal with this, we can just fill the whole thing
      # ahead of time. This could be optimized.
      if style.padding.any? || !@align.top?
        if alpha = style.alpha?
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
              line.dirty = true
            end
          end
        else
          screen.fill_region(default_attr, bch, xi, xl, yi, yl)
        end
      end

      p = style.padding
      xi += p.left
      xl -= p.right
      yi += p.top
      yl -= p.bottom

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

      # Draw the content and background.
      # yi.step to: yl-1 do |y|
      (yi...yl).each do |y|
        line = lines[y]?
        unless line
          if y >= screen.aheight || yl < ibottom
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
            if x >= screen.awidth || xl < iright
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
              attr = screen.attr2code(content, ci - 1, m, attr, default_attr)
              ci = m + 1
              # Ignore foreground changes for selected items (keep the default
              # foreground while letting the rest of the attr change).
              parent.try do |parent2|
                if parent2._is_list && parent2.interactive? && parent2.is_a?(Widget::List) && parent2.item_selected?(self) # XXX && parent2.invert_selected
                  attr = Attr.pack(Attr.flags(attr), Attr.fg(default_attr), Attr.bg(attr))
                end
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
            while x < xl
              cell = line[x]?
              if !cell
                break
              end
              if alpha = style.alpha?
                cell.attr = Colors.blend(attr, cell.attr, alpha: alpha)
                if content[ci - 1]?
                  cell.char = ch
                end
                line.dirty = true
              else
                if cell != {attr, ch}
                  cell.attr = attr
                  cell.char = ch
                  line.dirty = true
                end
              end
              x += 1
            end

            # It was a newline; we've filled the row to the end, we
            # can move to the next row.
            next
          end

          # Whether this cell maps to a real content codepoint (vs. the fill
          # char `bch` past the end of content).
          has_content = !content[ci - 1]?.nil?

          # Grapheme assembly (full_unicode): merge following combining marks /
          # joiners into one cluster, and lay wide (2-column) clusters across two
          # cells. Legacy keeps one codepoint per cell.
          #
          # `grapheme` is only consumed on the full_unicode path below; the
          # legacy path writes `ch` directly. So it stays `""` (no allocation)
          # unless full_unicode is on — this avoids a per-cell `ch.to_s` on the
          # default render path.
          grapheme = ""
          cell_width = 1
          if full_unicode?
            if has_content
              grapheme, ci = extend_grapheme(content, ci, ch)
              cell_width = ::Crysterm::Unicode.width grapheme
              if cell_width == 0
                # Zero-width cluster (e.g. a leading combining mark): merge into
                # the previous cell rather than consuming one.
                if x > xi && (prev = line[x - 1]?)
                  prev.grapheme = prev.grapheme + grapheme
                  line.dirty = true
                end
                x -= 1
                next
              end
            else
              # Fill char past the end of content: one codepoint, no clustering.
              grapheme = ch.to_s
            end
          end

          unless style.fill?
            next
          end

          if alpha = style.alpha?
            cell.attr = Colors.blend(attr, cell.attr, alpha: alpha)
            if has_content
              full_unicode? ? (cell.grapheme = grapheme) : (cell.char = ch)
            end
            line.dirty = true
          elsif full_unicode?
            if cell.attr != attr || !cell.grapheme_eq?(grapheme)
              cell.attr = attr
              cell.grapheme = grapheme
              line.dirty = true
            end
          else
            if cell != {attr, ch}
              cell.attr = attr
              cell.char = ch
              line.dirty = true
            end
          end

          # Wide grapheme: claim the following cell as its continuation so the
          # cell grid stays 1 cell == 1 terminal column.
          if full_unicode? && cell_width == 2 && (x + 1 < xl) && (nxt = line[x + 1]?)
            nxt.attr = attr
            nxt.continuation!
            line.dirty = true
            x += 1
          end
        end
      end

      # Draw the scrollbar.
      # Could possibly draw this after all child elements.
      i = 0
      @scrollbar.try do
        # D O:
        # i = @get_scroll_height()
        i = Math.max @_clines.size, _scroll_bottom
      end

      if coords.no_top? || coords.no_bottom?
        i = -Int32::MAX
      end

      @scrollbar.try do
        if (yl - yi) < i
          x = xl - 1
          sbr = style.border.try(&.right) || 0
          x += 1 if style.scrollbar.ignore_border? && (sbr > 0) # should 1 be sbr ?

          # Guard the denominators: when there is effectively nothing to scroll
          # (`denom <= 0`, e.g. content exactly one line tall) the division would
          # yield `Infinity`/`NaN` and the subsequent `.to_i` would raise
          # `OverflowError`. In that case the thumb simply sits at the top.
          if @always_scroll
            denom = i - (yl - yi)
            frac = denom <= 0 ? 0.0 : @child_base / denom
          else
            denom = i - 1
            frac = denom <= 0 ? 0.0 : (@child_base + @child_offset) / denom
          end

          y = yi + ((yl - yi) * frac).to_i
          y = yl - 1 if y >= yl

          # XXX The '?' was added ad-hoc to prevent exceptions when something goes out of
          # bounds (e.g. size of widget given too small for content).
          # Is there any better way to handle?
          lines[y]?.try do |line|
            line.[x]?.try do |cell|
              if @track
                ch = style.track.char
                attr = sattr style.track, style.track.fg, style.track.bg
                screen.fill_region attr, ch, x, x + 1, yi, yl
              end

              ch = style.scrollbar.char
              attr = sattr style.scrollbar, style.scrollbar.fg, style.scrollbar.bg

              if cell != {attr, ch}
                cell.attr = attr
                cell.char = ch
                line.dirty = true
              end
            end
          end
        end
      end

      # TODO See if these 4 values could be packed somehow to just replace individual
      # settings with the usual: style.border.try &.adjust(pos, -1) ?
      style.border.try do |border|
        xi -= border.left
        xl += border.right
        yi -= border.top
        yl += border.bottom
      end

      p = style.padding
      xi -= p.left
      xl += p.right
      yi -= p.top
      yl += p.bottom

      # Draw the border.
      style.border.try do |border|
        # A border with all sides 0 is "no border": nothing to draw.
        next unless border.any?

        battr = sattr border

        [yi, yl - 1].each do |y|
          line = lines[y]?
          next if y == -1 || !line

          # A 0-height top/bottom border was not expanded into its own row
          # (yi/yl-1 still sit on the content), so treat it exactly like
          # `no_top?`/`no_bottom?` and skip the whole row. Drawing here would
          # otherwise overwrite the content on that line.
          if y == yi && (coords.no_top? || border.top == 0)
            next
          elsif y == yl - 1 && (coords.no_bottom? || border.bottom == 0)
            next
          end

          (xi...xl).each do |x|
            next if coords.no_left? && x == xi
            next if coords.no_right? && x == xl - 1

            cell = line[x]?
            next unless cell

            ch = border_char(border, x, xi, xl, y, yi, yl, default_attr)

            if cell != {battr, ch}
              cell.attr = battr
              cell.char = ch
              line.dirty = true
            end
          end
        end

        (yi + 1...yl - 1).each do |y|
          line = lines[y]?
          next unless line

          [xi, xl - 1].each do |x|
            # A 0-width left/right border was not expanded into its own column
            # (xi/xl-1 still sit on the content), so skip it like a
            # `no_left?`/`no_right?` clip instead of overwriting text.
            next if border.left == 0 && x == xi
            next if border.right == 0 && x == xl - 1

            cell = line[x]?
            next unless cell

            ch = border_char(border, x, xi, xl, y, yi, yl, default_attr)

            if cell != {battr, ch}
              cell.attr = battr
              cell.char = ch
              line.dirty = true
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
          screen.blend_region s.alpha, xi - s.left, xi, Math.max(i, 0), l
        end

        if s.top?
          l = s.right? ? xl + s.right : (s.left? ? xl - s.left : xl)
          screen.blend_region s.alpha, Math.max(xi, 0), l, yi - s.top, yi
        end

        if s.right?
          i = (s.top? || s.left?) ? yi : yi + s.bottom
          l = s.bottom? ? yl + s.bottom : yl
          screen.blend_region s.alpha, xl, xl + s.right, Math.max(i, 0), l
        end

        if s.bottom?
          i = s.right? ? xi + (s.left? ? 0 : s.right) : xi
          l = xl - (s.left? && !s.top? && !s.right? ? s.left : 0)
          screen.blend_region s.alpha, Math.max(i, 0), l, yl, yl + s.bottom
        end
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
          screen._dock_stops[coords.yi] = true
          screen._dock_stops[coords.yl - 1] = true
        end
      end
    end

    @[AlwaysInline]
    def border_char(border, x, xi, xl, y, yi, yl, default_attr)
      if border.type.line?
        ch = case {x, y}
             when {xi, yi}         then border.left > 0 && border.top > 0 ? '┌' : (border.left == 0 && border.top > 0 ? '─' : '│')
             when {xl - 1, yi}     then border.right > 0 && border.top > 0 ? '┐' : (border.right == 0 && border.top > 0 ? '─' : '│')
             when {xi, yl - 1}     then border.left > 0 && border.bottom > 0 ? '└' : (border.left == 0 && border.bottom > 0 ? '─' : '│')
             when {xl - 1, yl - 1} then border.right > 0 && border.bottom > 0 ? '┘' : (border.right == 0 && border.bottom > 0 ? '─' : '│')
               # when [xi, yi + 1...yl - 1], [xl - 1, yi + 1...yl - 1] then '│'
               # else '─'
             else
               if (x == xi || x == xl - 1) && (y > yi && y < yl - 1)
                 '│'
               else
                 '─'
               end
             end
      elsif border.type.bg?
        ch = border.char
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
          (style.inverse? ? Attr::INVERSE : 0) |
          (style.blink? ? Attr::BLINK : 0) |
          (style.underline? ? Attr::UNDERLINE : 0) |
          (style.italic? ? Attr::ITALIC : 0) |
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
      lpos = _get_coords(get)
      return unless lpos
      screen.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, override)
    end
  end
end
