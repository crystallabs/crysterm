require "./pos"

class Crysterm::ShrinkBox
  property xi : Int32 = 0
  property xl : Int32 = 0
  property yi : Int32 = 0
  property yl : Int32 = 0
  property get : Bool = false

  def initialize(xi, xl, yi, yl, get = false)
  end
end

module Crysterm
  class Element < Node
    module Rendering
      include Crysterm::Element::Pos
      include Crystallabs::Helpers::Alias_Methods

      property items = [] of String

      # Here be dragons

      def _render
        emit PreRenderEvent

        parse_content

        coords = _get_coords(true)
        if (!coords)
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

        lines = @screen.lines
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
        content = @_pcontent || ""
        ci = @_clines.ci[coords.base]? || 0 # XXX Is it ok that array lookup can be nil? and defaulting to 0?
        # battr
        # dattr
        # c
        # visible
        # i
        bch = @ch

        # Disabled originally:
        # Clip content if it's off the edge of the screen
        # if (xi + @ileft < 0 || yi + @itop < 0)
        #   clines = @_clines.slice()
        #   if (xi + @ileft < 0)
        #     for (i = 0; i < clines.size; i++)
        #       t = 0
        #       csi = ''
        #       csis = ''
        #       for (j = 0; j < clines[i].size; j++)
        #         while (clines[i][j] == '\x1b')
        #           csi = '\x1b'
        #           while (clines[i][j++] != 'm') csi += clines[i][j]
        #           csis += csi
        #         end
        #         if (++t == -(xi + @ileft) + 1) break
        #       end
        #       clines[i] = csis + clines[i].substring(j)
        #     end
        #   end
        #   if (yi + @itop < 0)
        #     clines = clines.slice(-(yi + @itop))
        #   end
        #   content = clines.join('\n')
        # end

        if (coords.base >= @_clines.ci.size)
          # Can be @_pcontent, but this is the same here, plus not_nil!
          ci = content.size
        end

        @lpos = coords

        @border.try do |border|
          if (border.type == BorderType::Line)
            @screen._border_stops[coords.yi] = true
            @screen._border_stops[coords.yl - 1] = true
            # D O:
            # if (!@screen._border_stops[coords.yi])
            #   @screen._border_stops[coords.yi] = { xi: coords.xi, xl: coords.xl }
            # else
            #   if (@screen._border_stops[coords.yi].xi > coords.xi)
            #     @screen._border_stops[coords.yi].xi = coords.xi
            #   end
            #   if (@screen._border_stops[coords.yi].xl < coords.xl)
            #     @screen._border_stops[coords.yi].xl = coords.xl
            #   end
            # end
            # @screen._border_stops[coords.yl - 1] = @screen._border_stops[coords.yi]
          end
        end

        dattr = sattr(@style)
        attr = dattr

        # If we're in a scrollable text box, check to
        # see which attributes this line starts with.
        if (ci > 0)
          attr = @_clines.attr.try(&.[Math.min(coords.base, @_clines.size - 1)]?) || 0
        end

        if (@border)
          xi += 1
          xl -= 1
          yi += 1
          yl -= 1
        end

        # If we have padding/valign, that means the
        # content-drawing loop will skip a few cells/lines.
        # To deal with this, we can just fill the whole thing
        # ahead of time. This could be optimized.
        if (@padding.any? || (@valign && (@valign != "top")))
          if @style.try &.transparent
            (Math.max(yi, 0)...yl).each do |y|
              if (!lines[y]?)
                break
              end
              (Math.max(xi, 0)...xl).each do |x|
                if (!lines[y][x]?)
                  break
                end
                lines[y][x].attr = Colors.blend(attr, lines[y][x].attr)
                # D O:
                # lines[y][x].char = bch
                lines[y].dirty = true
              end
            end
          else
            @screen.fill_region(dattr, bch, xi, xl, yi, yl)
          end
        end

        if @padding.any?
          xi += @padding.left
          xl -= @padding.right
          yi += @padding.top
          yl -= @padding.bottom
        end

        # Determine where to place the text if it's vertically aligned.
        if (@valign == "middle" || @valign == "bottom")
          visible = yl - yi
          if (@_clines.size < visible)
            if (@valign == "middle")
              visible = visible // 2
              visible -= @_clines.size // 2
            elsif (@valign == "bottom")
              visible -= @_clines.size
            end
            ci -= visible * (xl - xi)
          end
        end

        # Draw the content and background.
        # yi.step to: yl-1 do |y|
        (yi...yl).each do |y|
          if (!lines[y]?)
            if (y >= @screen.height || yl < @ibottom)
              break
            else
              next
            end
          end
          # TODO - make cell exist only if there's something to be drawn there?
          (xi...xl).each do |x|
            cell = lines[y][x]?
            if (!cell)
              if (x >= @screen.width || xl < @iright)
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
            while (ch == "\x1b")
              cnt = content[(ci - 1)..]
              if (c = cnt.match /^\x1b\[[\d;]*m/)
                ci += c[0].size - 1
                attr = @screen.attr_code(c[0], attr, dattr)
                # D O:
                # Ignore foreground changes for selected items.
                # XXX But, Enable when lists exist, then restrict to List
                # if (parent = @parent) && parent.is_a? Crysterm::Element
                #  if (parent._isList && parent.interactive && parent.items[parent.selected] == self && parent.options.invert_selected != false)
                #    attr = (attr & ~(0x1ff << 9)) | (dattr & (0x1ff << 9))
                #  end
                # end
                ch = content[ci] || bch
                ci += 1
              else
                break
              end
            end

            # Handle newlines.
            if (ch == '\t')
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
                if @style.try &.transparent
                  lines[y][x].attr = Colors.blend(attr, lines[y][x].attr)
                  if (content[ci]?)
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
              next
            end

            # TODO
            # if (@screen.full_unicode && content[ci - 1])
            if (content.try &.[ci - 1]?)
              point = content.codepoint_at(ci - 1)
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

            if @_no_fill
              next
            end

            if @style.try &.transparent
              lines[y][x].attr = Colors.blend(attr, lines[y][x].attr)
              if (content[ci]?)
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

        if (coords.notop || coords.nobot)
          i = -Int32::MAX
        end
        # Draw the scrollbar.
        # Could possibly draw this after all child elements.
        # @scrollbar.try do |scrollbar|
        #  # D O:
        #  # i = @get_scroll_height()
        #  # TODO:
        #  # (Scroll bottom is from scrollable)
        #  #i = Math.max(@_clines.size, _scroll_bottom())
        #  i = Math.max(@_clines.size, 0)

        #  if ((yl - yi) < i)
        #    x = xl - 1
        #    if (scrollbar.ignore_border && @border)
        #      x+=1
        #    end
        #    if (@always_scroll)
        #      y = @child_base / (i - (yl - yi))
        #    else
        #      y = (@child_base + @child_offset) / (i - 1)
        #    end
        #    y = yi + ((yl - yi) * y)
        #    if (y >= yl)
        #      y = yl - 1
        #    end
        #    cell = lines[y] && lines[y][x]
        #    if (cell)
        #      if (@track)
        #        ch = @track.ch || ' '
        #        attr = sattr(@style.track,
        #          @style.track.fg || @style.fg,
        #          @style.track.bg || @style.bg)
        #        @screen.fill_region(attr, ch, x, x + 1, yi, yl)
        #      end
        #      ch = scrollbar.ch || ' '
        #      attr = sattr(@style.scrollbar,
        #        @style.scrollbar.fg || @style.fg,
        #        @style.scrollbar.bg || @style.bg)
        #      if cell != {attr, ch}
        #        lines[y][x].attr = attr
        #        lines[y][x].char = ch.is_a?(String) ? ch[0] : ch
        #        lines[y].dirty = true
        #      end
        #    end
        #  end
        # end

        if (@border)
          xi -= 1
          xl += 1
          yi -= 1
          yl += 1
        end

        if @padding.any?
          xi -= @padding.left
          xl += @padding.right
          yi -= @padding.top
          yl += @padding.bottom
        end

        # Draw the border.
        if (border = @border)
          battr = sattr(@style.try &.border)
          y = yi
          if (coords.notop)
            y = -1
          end
          (xi...xl).each do |x|
            if (!lines[y]?)
              break
            end
            if (coords.noleft && x == xi)
              next
            end
            if (coords.noright && x == xl - 1)
              next
            end
            cell = lines[y][x]?
            if (!cell)
              next
            end
            if (border.type == BorderType::Line)
              if (x == xi)
                ch = '\u250c' # '┌'
                if (!border.left)
                  if (border.top)
                    ch = '\u2500'
                    # '─'
                  else
                    next
                  end
                else
                  if (!border.top)
                    ch = '\u2502'
                    # '│'
                  end
                end
              elsif (x == xl - 1)
                ch = '\u2510' # '┐'
                if (!border.right)
                  if (border.top)
                    ch = '\u2500'
                    # '─'
                  else
                    next
                  end
                else
                  if (!border.top)
                    ch = '\u2502'
                    # '│'
                  end
                end
              else
                ch = '\u2500'
                # '─'
              end
            elsif (border.type == BorderType::Bg)
              ch = border.ch
            end
            if (!border.top && x != xi && x != xl - 1)
              ch = ' '
              if cell != {dattr, ch}
                lines[y][x].attr = dattr
                lines[y][x].char = ch
                lines[y].dirty = true
                next
              end
            end
            if cell != {battr, ch}
              lines[y][x].attr = battr
              lines[y][x].char = ch ? ch : ' ' # XXX why ch can be nil?
              lines[y].dirty = true
            end
          end
          y = yi + 1
          while (y < yl - 1)
            if (!lines[y]?)
              next
            end
            cell = lines[y][xi]?
            if (cell)
              if (border.left)
                if (border.type == BorderType::Line)
                  ch = '\u2502'
                  # '│'
                elsif (border.type == BorderType::Bg)
                  ch = border.ch
                end
                if (!coords.noleft)
                  if cell != {battr, ch}
                    lines[y][xi].attr = battr
                    lines[y][xi].char = ch ? ch : ' '
                    lines[y].dirty = true
                  end
                end
              else
                ch = ' '
                if cell != {dattr, ch}
                  lines[y][xi].attr = dattr
                  lines[y][xi].char = ch ? ch : ' '
                  lines[y].dirty = true
                end
              end
            end
            cell = lines[y][xl - 1]?
            if (cell)
              if (border.right)
                if (border.type == BorderType::Line)
                  ch = '\u2502'
                  # '│'
                elsif (border.type == BorderType::Bg)
                  ch = border.ch
                end
                if (!coords.noright)
                  if cell != {battr, ch}
                    lines[y][xl - 1].attr = battr
                    lines[y][xl - 1].char = ch ? ch : ' '
                    lines[y].dirty = true
                  end
                end
              else
                ch = ' '
                if cell != {dattr, ch}
                  lines[y][xl - 1].attr = dattr
                  lines[y][xl - 1].char = ch ? ch : ' '
                  lines[y].dirty = true
                end
              end
            end
            y += 1
          end
          y = yl - 1
          if (coords.nobot)
            y = -1
          end
          (xi...xl).each do |x|
            if (!lines[y]?)
              break
            end
            if (coords.noleft && x == xi)
              next
            end
            if (coords.noright && x == xl - 1)
              next
            end
            cell = lines[y][x]?
            if (!cell)
              next
            end
            if (border.type == BorderType::Line)
              if (x == xi)
                ch = '\u2514' # '└'
                if (!border.left)
                  if (border.bottom)
                    ch = '\u2500'
                    # '─'
                  else
                    next
                  end
                else
                  if (!border.bottom)
                    ch = '\u2502'
                    # '│'
                  end
                end
              elsif (x == xl - 1)
                ch = '\u2518' # '┘'
                if (!border.right)
                  if (border.bottom)
                    ch = '\u2500'
                    # '─'
                  else
                    next
                  end
                else
                  if (!border.bottom)
                    ch = '\u2502'
                    # '│'
                  end
                end
              else
                ch = '\u2500'
                # '─'
              end
            elsif (border.type == BorderType::Bg)
              ch = border.ch
            end
            if (!border.bottom && x != xi && x != xl - 1)
              ch = ' '
              if cell != {dattr, ch}
                lines[y][x].attr = dattr
                lines[y][x].char = ch ? ch : ' '
                lines[y].dirty = true
              end
              next
            end
            if cell != {battr, ch}
              lines[y][x].attr = battr
              lines[y][x].char = ch ? ch : ' '
              lines[y].dirty = true
            end
          end
        end

        if (@shadow)
          # right
          y = Math.max(yi + 1, 0)
          while (y < yl + 1)
            if (!lines[y]?)
              break
            end
            x = xl
            while (x < xl + 2)
              if (!lines[y][x]?)
                break
              end
              # D O:
              # lines[y][x].attr = Colors.blend(@dattr, lines[y][x].attr)
              lines[y][x].attr = Colors.blend(lines[y][x].attr)
              lines[y].dirty = true
              x += 1
            end
            y += 1
          end
          # bottom
          y = yl
          while (y < yl + 1)
            if (!lines[y]?)
              break
            end
            (Math.max(xi + 1, 0)...xl).each do |x|
              if (!lines[y][x]?)
                break
              end
              # D O:
              # lines[y][x].attr = Colors.blend(@dattr, lines[y][x].attr)
              lines[y][x].attr = Colors.blend(lines[y][x].attr)
              lines[y].dirty = true
            end
            y += 1
          end
        end

        @children.each do |el|
          if el.screen._ci != -1
            el.index = el.screen._ci
            el.screen._ci += 1
          end

          el.render
        end

        emit RenderEvent # , coords

        coords
      end

      def render
        _render
      end
    end
  end
end
