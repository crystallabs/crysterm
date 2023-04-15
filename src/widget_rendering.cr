module Crysterm
  class Widget
    # module Rendering
    include Crystallabs::Helpers::Alias_Methods

    # What action to take when widget is overflowing parent's rectangle?
    property overflow = Overflow::Ignore

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
          if parent2.items[parent2.selected]? == self
            style = parent2.styles.selected
          else
            style = parent2.style.item
          end
        end
      end

      process_content

      coords = _get_coords(true)
      unless coords
        @lpos = nil
        return
      end

      if (coords.xl - coords.xi <= 0)
        coords.xl = Math.max(coords.xl, coords.xi)
        return
      end

      if (coords.yl - coords.yi <= 0)
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
      content = StringIndex.new @_pcontent || ""
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

      if (coords.base >= @_clines.ci.size)
        # Can be @_pcontent, but this is the same here, plus not_nil!
        ci = content.size
      end

      @lpos = coords

      style.border.try do |border|
        if border.type.line?
          screen._border_stops[coords.yi] = true
          screen._border_stops[coords.yl - 1] = true
          # D O:
          # if (!screen._border_stops[coords.yi])
          #   screen._border_stops[coords.yi] = { xi: coords.xi, xl: coords.xl }
          # else
          #   if (screen._border_stops[coords.yi].xi > coords.xi)
          #     screen._border_stops[coords.yi].xi = coords.xi
          #   end
          #   if (screen._border_stops[coords.yi].xl < coords.xl)
          #     screen._border_stops[coords.yi].xl = coords.xl
          #   end
          # end
          # screen._border_stops[coords.yl - 1] = screen._border_stops[coords.yi]
        end
      end

      default_attr = sattr style
      attr = default_attr

      # If we're in a scrollable text box, check to
      # see which attributes this line starts with.
      if (ci > 0)
        attr = @_clines.attr.try(&.[Math.min(coords.base, @_clines.size - 1)]?) || 0
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
            if !lines[y]?
              break
            end
            (Math.max(xi, 0)...xl).each do |x|
              if !lines[y][x]?
                break
              end
              lines[y][x].attr = Colors.blend(attr, lines[y][x].attr, alpha: alpha)
              # D O:
              # lines[y][x].char = bch
              lines[y].dirty = true
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
        if (@_clines.size < visible)
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
        if (!lines[y]?)
          if (y >= screen.aheight || yl < ibottom)
            break
          else
            next
          end
        end
        # TODO - make cell exist only if there's something to be drawn there?
        x = xi - 1
        while x < xl - 1
          x += 1
          cell = lines[y][x]?
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
          while (ch == '\e')
            cnt = content[(ci - 1)..]
            if c = cnt.match SGR_REGEX_AT_BEGINNING
              ci += c[0].size - 1
              attr = screen.attr2code(c[0], attr, default_attr)
              # Ignore foreground changes for selected items.
              parent.try do |parent2|
                if parent2._is_list && parent2.interactive? && parent2.is_a?(Widget::List) && parent2.items[parent2.selected] == self # XXX && parent2.invert_selected
                  attr = (attr & ~(0x1ff << 9)) | (default_attr & (0x1ff << 9))
                end
              end
              ch = content[ci]? || bch
              ci += 1
            else
              break
            end
          end

          # Handle newlines.
          if (ch == '\t')
            # TODO this should be something like ch = bch * style.tab_size, or just style.tab_char,
            # (although not as simple as that.)
            ch = bch
          end
          if (ch == '\n')
            # If we're on the first cell and we find a newline and the last cell
            # of the last line was not a newline, let's just treat this like the
            # newline was already "counted".
            if ((x == xi) && (y != yi) && (content[ci - 2]? != '\n'))
              x -= 1
              next
            end
            # We could use fill_region here, name the
            # outer loop, and continue to it instead.
            ch = bch
            while (x < xl)
              cell = lines[y][x]?
              if (!cell)
                break
              end
              if alpha = style.alpha?
                lines[y][x].attr = Colors.blend(attr, lines[y][x].attr, alpha: alpha)
                if content[ci - 1]?
                  lines[y][x].char = ch
                end
                lines[y].dirty = true
              else
                if cell != {attr, ch}
                  lines[y][x].attr = attr
                  lines[y][x].char = ch
                  lines[y].dirty = true
                end
              end
              x += 1
            end

            # It was a newline; we've filled the row to the end, we
            # can move to the next row.
            next
          end

          # TODO
          # if (screen.full_unicode && content[ci - 1])
          if (content[ci - 1]?)
            # point = content.codepoint_at(ci - 1) # Unused
            # TODO
            # # Handle combining chars:
            # # Make sure they get in the same cell and are counted as 0.
            # if (unicode.combining[point])
            #  if (point > 0x00ffff)
            #    ch = content[ci - 1] + content[ci]
            #    ci++
            #  end
            #  if (x - 1 >= xi)
            #    lines[y][x - 1][1] += ch
            #  elsif (y - 1 >= yi)
            #    lines[y - 1][xl - 1][1] += ch
            #  end
            #  x-=1
            #  next
            # end
            # Handle surrogate pairs:
            # Make sure we put surrogate pair chars in one cell.
            # if (point > 0x00ffff)
            #  ch = content[ci - 1] + content[ci]
            #  ci++
            # end
          end

          unless style.fill?
            next
          end

          if alpha = style.alpha?
            lines[y][x].attr = Colors.blend(attr, lines[y][x].attr, alpha: alpha)
            if content[ci - 1]?
              lines[y][x].char = ch
            end
            lines[y].dirty = true
          else
            if cell != {attr, ch}
              lines[y][x].attr = attr
              lines[y][x].char = ch
              lines[y].dirty = true
            end
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

          if @always_scroll
            y = @child_base / (i - (yl - yi))
          else
            y = (@child_base + @child_offset) / (i - 1)
          end

          y = yi + ((yl - yi) * y).to_i
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
        battr = sattr border

        [yi, yl - 1].each do |y|
          next if y == -1 || !lines[y]?

          if y == yi && coords.no_top?
            next
          elsif y == yl - 1 && coords.no_bottom?
            next
          end

          (xi...xl).each do |x|
            next if coords.no_left? && x == xi
            next if coords.no_right? && x == xl - 1

            cell = lines[y][x]?
            next unless cell

            ch = border_char(border, x, xi, xl, y, yi, yl, default_attr)

            if cell != {battr, ch}
              cell.attr = battr
              cell.char = ch
              lines[y].dirty = true
            end
          end
        end

        (yi + 1...yl - 1).each do |y|
          next unless lines[y]?

          [xi, xl - 1].each do |x|
            cell = lines[y][x]?
            next unless cell

            ch = border_char(border, x, xi, xl, y, yi, yl, default_attr)

            if cell != {battr, ch}
              cell.attr = battr
              cell.char = ch
              lines[y].dirty = true
            end
          end
        end
      end

      # Shadow
      if (s = style.shadow) && s.any?
        if s.left?
          i = (yi - s.top) + (s.bottom? && !s.top? && !s.right? ? s.bottom : 0)
          l = s.bottom? ? yl + s.bottom : yl - (s.top? && !s.bottom? ? s.top : 0)

          (Math.max(i, 0)...l).each do |y|
            break unless lines[y]?

            x = xi - s.left
            while x < xi
              break unless lines[y][x]?

              lines[y][x].attr = Colors.blend(lines[y][x].attr, alpha: s.alpha)
              lines[y].dirty = true
              x += 1
            end
          end
        end

        if s.top?
          l = s.right? ? xl + s.right : (s.left? ? xl - s.left : xl)

          (yi - s.top...yi).each do |y|
            break unless lines[y]?

            (Math.max(xi, 0)...l).each do |x|
              break unless lines[y][x]?

              lines[y][x].attr = Colors.blend(lines[y][x].attr, alpha: s.alpha)
              lines[y].dirty = true
            end
          end
        end

        if s.right?
          i = (s.top? || s.left?) ? yi : yi + s.bottom
          l = s.bottom? ? yl + s.bottom : yl

          (Math.max(i, 0)...l).each do |y|
            break unless lines[y]?

            x = xl
            while x < xl + s.right
              break unless lines[y][x]?

              lines[y][x].attr = Colors.blend(lines[y][x].attr, alpha: s.alpha)
              lines[y].dirty = true
              x += 1
            end
          end
        end

        if s.bottom?
          i = s.right? ? xi + (s.left? ? 0 : s.right) : xi
          l = xl - (s.left? && !s.top? && !s.right? ? s.left : 0)

          (yl...yl + s.bottom).each do |y|
            break unless lines[y]?

            (Math.max(i, 0)...l).each do |x|
              break unless lines[y][x]?

              lines[y][x].attr = Colors.blend(lines[y][x].attr, alpha: s.alpha)
              lines[y].dirty = true
            end
          end
        end
      end

      if with_children
        @children.each do |el|
          if el.screen._ci != -1
            el.index = el.screen._ci
            el.screen._ci += 1
          end

          el.render
        end
      end

      emit Crysterm::Event::Rendered # , coords

      coords
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

      ch = ' ' if (border.top == 0 && y == yi || border.bottom == 0 && y == yl - 1) && x != xi && x != xl - 1

      ch || ' ' # Just a failsafe
    end

    def render(with_children = true)
      _render with_children
    end

    def self.sattr(style, fg = nil, bg = nil)
      if fg.nil? && bg.nil?
        fg = style.fg
        bg = style.bg
      end

      # TODO support style.* being Procs ?

      # D O:
      # return (this.uid << 24)
      #   | ((this.dockBorders ? 32 : 0) << 18)
      ((style.visible? ? 0 : 16) << 18) |
        ((style.inverse? ? 8 : 0) << 18) |
        ((style.blink? ? 4 : 0) << 18) |
        ((style.underline? ? 2 : 0) << 18) |
        ((style.bold? ? 1 : 0) << 18) |
        (Colors.convert(fg) << 9) |
        Colors.convert(bg)
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
      return unless @screen
      lpos = _get_coords(get)
      return unless lpos
      screen.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, override)
    end
  end
end
