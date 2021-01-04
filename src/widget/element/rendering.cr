require "./pos"

class Crysterm::ShrinkBox
  property xi : Int32 = 0
  property xl : Int32 = 0
  property yi : Int32 = 0
  property yl : Int32 = 0
  property get : Bool = false
  def initialize(xi,xl,yi,yl, get=false)
  end
end

module Crysterm::Widget
  class Element < Node
    module Rendering
      include Crysterm::Widget::Element::Pos

      property items = [] of String

      # Here be dragons

      def _get_shrink_box(xi, xl, yi, yl, get)
        if (@children.size == 0)
          return ShrinkBox.new xi: xi, xl: xi + 1, yi: yi, yl: yi + 1
        end

        #i, el, ret,
        mxi = xi
        mxl = xi + 1
        myi = yi
        myl = yi + 1

        # This is a chicken and egg problem. We need to determine how the children
        # will render in order to determine how this element renders, but it in
        # order to figure out how the children will render, they need to know
        # exactly how their parent renders, so, we can give them what we have so
        # far.
        #_lpos
        if (get)
          _lpos = @lpos
          @lpos = LPos.new xi: xi, xl: xl, yi: yi, yl: yl
          # D O:
          #@shrink = false
        end

        @children.each_with_index do |el, i|
          ret = el._get_coords(get)

          # D O:
          # Or just (seemed to work, but probably not good):
          # ret = el.lpos || @lpos

          if (!ret)
            next
          end

          # Since the parent element is shrunk, and the child elements think it's
          # going to take up as much space as possible, an element anchored to the
          # right or bottom will inadvertantly make the parent's shrunken size as
          # large as possible. So, we can just use the height and/or width the of
          # element.
          # if (get)
          if (el.position.left.nil? && el.position.right.any?)
            ret.xl = xi + (ret.xl - ret.xi)
            ret.xi = xi
            if (@screen.auto_padding)
              # Maybe just do this no matter what.
              ret.xl += @ileft
              ret.xi += @ileft
            end
          end
          if (el.position.top.nil? && el.position.bottom.any?)
            ret.yl = yi + (ret.yl - ret.yi)
            ret.yi = yi
            if (@screen.auto_padding)
              # Maybe just do this no matter what.
              ret.yl += @itop
              ret.yi += @itop
            end
          end

          if (ret.xi < mxi)
            mxi = ret.xi
          end
          if (ret.xl > mxl)
            mxl = ret.xl
          end
          if (ret.yi < myi)
            myi = ret.yi
          end
          if (ret.yl > myl)
            myl = ret.yl
          end
        end

        if (get)
          @lpos = _lpos.not_nil!
          # D O:
          #@shrink = true
        end

        if (@position.width.nil?  && (@position.left.nil?  || @position.right.nil?))
          if (@position.left.nil? && @position.right.any?)
            xi = xl - (mxl - mxi)
            if (!@screen.auto_padding)
              xi -= @padding.left + @padding.right
            else
              xi -= @ileft
            end
          else
            xl = mxl
            if (!@screen.auto_padding)
              xl += @padding.left + @padding.right
              # XXX Temporary workaround until we decide to make auto_padding default.
              # See widget-listtable.js for an example of why this is necessary.
              # XXX Maybe just to this for all this being that this would affect
              # width shrunken normal shrunken lists as well.
              # if (@_isList)
              if (@type == :"list-table")
                xl -= @padding.left + @padding.right
                xl += @iright
              end
            else
              #xl += @padding.right
              xl += @iright
            end
          end
        end
        if (@position.height.nil?  && (@position.top.nil?  || @position.bottom.nil?) && (!@scrollable || @_isList))
          # NOTE: Lists get special treatment if they are shrunken - assume they
          # want all list items showing. This is one case we can calculate the
          # height based on items/boxes.
          if (@_isList)
            myi = 0 - @itop
            myl = @items.size + @ibottom
          end
          if (@position.top.nil? && @position.bottom.any?)
            yi = yl - (myl - myi)
            if (!@screen.auto_padding)
              yi -= @padding.top + @padding.bottom
            else
              yi -= @itop
            end
          else
            yl = myl
            if (!@screen.auto_padding)
              yl += @padding.top + @padding.bottom
            else
              yl += @ibottom
            end
          end
        end

        ShrinkBox.new xi: xi, xl: xl, yi: yi, yl: yl
      end

      def _get_coords(get, noscroll=false)
        if (@hidden)
          return
        end

        # D O:
        # if (@parent._rendering)
        #   get = true
        # end

        xi = _get_left(get)
        xl = xi + _get_width(get)
        yi = _get_top(get)
        yl = yi + _get_height(get)
        base = @child_base || 0
        el = self
        fixed = @fixed
        #coords
        #v
        #noleft
        #noright
        #notop
        #nobot
        #ppos
        #b

        # Attempt to shrink the element base on the
        # size of the content and child elements.
        if @shrink
          coords = _get_shrink(xi, xl, yi, yl, get)
          xi = coords.xi
          xl = coords.xl
          yi = coords.yi
          yl = coords.yl
        end

        # Find a scrollable ancestor if we have one.
        while (el = el.parent)
          if (el.scrollable?)
            if (fixed)
              fixed = false
              next
            end
            break
          end
        end

        # Check to make sure we're visible and
        # inside of the visible scroll area.
        # NOTE: Lists have a property where only
        # the list items are obfuscated.

        # Old way of doing things, this would not render right if a shrunken element
        # with lots of boxes in it was within a scrollable element.
        # See: $ c test/widget-shrink-fail.cr
        # thisparent = @parent

        thisparent = el
        # Using thisparent && el here to restrict both to non-nil

        if (thisparent && el && !noscroll)
          ppos = thisparent.lpos

          # The shrink option can cause a stack overflow
          # by calling _get_coords on the child again.
          # if (!get && !thisparent.shrink)
          #   ppos = thisparent._get_coords()
          # end

          if (!ppos)
            p :no_ppos
            return
          end

          # TODO: Figure out how to fix base (and cbase to only
          # take into account the *parent's* padding.

          yi -= ppos.base
          yl -= ppos.base

          b = thisparent.border ? 1 : 0

          # XXX
          # Fixes non-`fixed` labels to work with scrolling (they're ON the border):
          # if (@position.left < 0 || @position.right < 0 || @position.top < 0 || @position.bottom < 0)
          if (@_isLabel)
            b = 0
          end

          if (yi < ppos.yi + b)
            if (yl - 1 < ppos.yi + b)
              # Is above.
              p :is_above
              return
            else
              # Is partially covered above.
              notop = true
              v = ppos.yi - yi
              if (@border)
                v-=1
              end
              if (thisparent.border)
                v+=1
              end
              base += v
              yi += v
            end
          elsif (yl > ppos.yl - b)
            if (yi > ppos.yl - 1 - b)
              # Is below.
              p :is_below
              return
            else
              # Is partially covered below.
              nobot = true
              v = yl - ppos.yl
              if (@border)
                v-=1
              end
              if (thisparent.border)
                v+=1
              end
              yl -= v
            end
          end

          # Shouldn't be necessary.
          # (yi < yl) || raise "No good"
          if (yi >= yl)
            p :failsafe
            return
          end

          unless el_lpos = el.lpos
            puts :Unexpected
            return
          end

          # Could allow overlapping stuff in scrolling elements
          # if we cleared the pending buffer before every draw.
          if (xi < el_lpos.xi)
            xi = el_lpos.xi
            noleft = true
            if (@border)
              xi-=1
            end
            if (thisparent.border)
              xi+=1
            end
          end
          if (xl > el_lpos.xl)
            xl = el_lpos.xl
            noright = true
            if (@border)
              xl+=1
            end
            if (thisparent.border)
              xl-=1
            end
          end
          #if (xi > xl)
          #  return
          #end
          if (xi >= xl)
            return
          end
        end

        parent = @parent.not_nil!

        # TODO causes may-hem
        #if (@no_overflow && parent.lpos)
        #  if (xi < parent.lpos.xi + parent.ileft)
        #    xi = parent.lpos.xi + parent.ileft
        #  end
        #  if (xl > parent.lpos.xl - parent.iright)
        #    xl = parent.lpos.xl - parent.iright
        #  end
        #  if (yi < parent.lpos.yi + parent.itop)
        #    yi = parent.lpos.yi + parent.itop
        #  end
        #  if (yl > parent.lpos.yl - parent.ibottom)
        #    yl = parent.lpos.yl - parent.ibottom
        #  end
        #end

        # D O:
        # if (parent.lpos)
        #   parent.lpos._scroll_bottom = Math.max(parent.lpos._scroll_bottom, yl)
        # end
        #p xi, xl, yi, xl

        v = LPos.new \
          xi: xi,
          xl: xl,
          yi: yi,
          yl: yl,
          base: base,
          # TODO || falses
          noleft: noleft || false,
          noright: noright || false,
          notop: notop || false,
          nobot: nobot || false,
          renders: @screen.renders
        p v
        v
      end

      def render()
        emit PreRenderEvent

        parse_content

        coords = _get_coords(true)
        if (!coords)
          @lpos = nil
          return
        end

        if (coords.xl - coords.xi <= 0)
          coords.xl = Math.max(coords.xl, coords.xi)
          p :bad1
          return
        end

        if (coords.yl - coords.yi <= 0)
          coords.yl = Math.max(coords.yl, coords.yi)
          p :bad2
          return
        end

        lines = @screen.lines
        xi = coords.xi
        xl = coords.xl
        yi = coords.yi
        yl = coords.yl
        #x
        #y
        #cell
        #attr
        #ch
        content = @_pcontent || ""
        ci = @_clines.ci[coords.base]
        #battr
        #dattr
        #c
        #visible
        #i
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
          if (border.type == Tput::BorderType::Line)
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
          xi+=1
          xl-=1
          yi+=1
          yl-=1
        end

        # If we have padding/valign, that means the
        # content-drawing loop will skip a few cells/lines.
        # To deal with this, we can just fill the whole thing
        # ahead of time. This could be optimized.
        if (tpadding || (@valign && @valign != "top"))
          if @style.try &.transparent
            (Math.max(yi, 0)...yl).each do |y|
              if (!lines[y]?)
                break
              end
              (Math.max(xi, 0)...xl).each do |x|
                if (!lines[y][x]?)
                  break
                end
                # TODO
                #lines[y][x].attr= colors.blend(attr, lines[y][x].attr)
                lines[y][x].attr= 0
                # D O:
                # lines[y][x].char = bch
                lines[y].dirty = true
              end
            end
          else
            @screen.fill_region(dattr, bch, xi, xl, yi, yl)
          end
        end

        if (tpadding)
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
        (yi...yl).each do |y|
          if (!lines[y]?)
            if (y >= @screen.height || yl < @ibottom)
              break
            else
              next
            end
          end
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
            ci += 1

            # D O:
            # if (!content[ci] && !coords._content_end)
            #   coords._content_end = { x: x - xi, y: y - yi }
            # end

            # Handle escape codes.
            while (ch == "\x1b")
              cnt = content[(ci-1)..]
              if (c = cnt.match /^\x1b\[[\d;]*m/)
                ci += c[0].size - 1
                attr = @screen.attr_code(c[0], attr, dattr)
                # D O:
                # Ignore foreground changes for selected items.
                # XXX But, Enable when lists exist, then restrict to List
                #if (parent = @parent) && parent.is_a? Crysterm::Widget::Element
                #  if (parent._isList && parent.interactive && parent.items[parent.selected] == self && parent.options.invert_selected != false)
                #    attr = (attr & ~(0x1ff << 9)) | (dattr & (0x1ff << 9))
                #  end
                #end
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
                x-=1
                next
              end
              # We could use fill_region here, name the
              # outer loop, and continue to it instead.
              ch = bch
              while(x < xl)
                cell = lines[y][x]?
                if (!cell)
                  break
                end
                if @style.try &.transparent
                  # TODO
                  #lines[y][x].attr = colors.blend(attr, lines[y][x].attr)
                  lines[y][x].attr = 0
                  if (content[ci]?)
                    lines[y][x].char = ch
                  end
                  lines[y].dirty = true
                else
                  if (attr != cell.attr || ch != cell.char)
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
            #if (@screen.full_unicode && content[ci - 1])
            if (content.try &.[ci - 1]?)
              point = content.codepoint_at(ci - 1)
              # TODO
              ## Handle combining chars:
              ## Make sure they get in the same cell and are counted as 0.
              #if (unicode.combining[point])
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
              #end
              # Handle surrogate pairs:
              # Make sure we put surrogate pair chars in one cell.
              #if (point > 0x00ffff)
              #  ch = content[ci - 1] + content[ci]
              #  ci++
              #end
            end

            if @style.try &.transparent
              # XXX lines[y][x].attr = colors.blend(attr, lines[y][x].attr)
              lines[y][x].attr = 0
              if (content[ci]?)
                lines[y][x].char = ch
              end
              lines[y].dirty = true
            else
              if ((attr != cell.attr) || (ch != cell.char))
                lines[y][x].attr = attr
                lines[y][x].char = ch
                lines[y].dirty = true
              end
            end
          end
        end

        # Draw the scrollbar.
        # Could possibly draw this after all child elements.
        if (@scrollbar)
          # D O:
          # i = @get_scroll_height()
          # TODO:
          # (Scroll bottom is from scrollable)
          #i = Math.max(@_clines.size, _scroll_bottom)
          i = @_clines.size
        end
        if (coords.notop || coords.nobot)
          i = -Int32::MAX
        end
        ###if (@scrollbar && (yl - yi) < i)
        ###  x = xl - 1
        ###  if (@scrollbar.ignore_border && @border)
        ###    x+=1
        ###  end
        ###  if (@always_scroll)
        ###    y = @child_base / (i - (yl - yi))
        ###  else
        ###    y = (@child_base + @child_offset) / (i - 1)
        ###  end
        ###  y = yi + ((yl - yi) * y)
        ###  if (y >= yl)
        ###    y = yl - 1
        ###  end
        ###  cell = lines[y] && lines[y][x]
        ###  if (cell)
        ###    if (@track)
        ###      ch = @track.ch || ' '
        ###      attr = sattr(@style.track,
        ###        @style.track.fg || @style.fg,
        ###        @style.track.bg || @style.bg)
        ###      @screen.fill_region(attr, ch, x, x + 1, yi, yl)
        ###    end
        ###    ch = @scrollbar.ch || ' '
        ###    attr = sattr(@style.scrollbar,
        ###      @style.scrollbar.fg || @style.fg,
        ###      @style.scrollbar.bg || @style.bg)
        ###    if (attr != cell.attr || ch != cell.char)
        ###      lines[y][x].attr = attr
        ###      lines[y][x].char = ch.is_a?(String) ? ch[0] : ch
        ###      lines[y].dirty = true
        ###    end
        ###  end
        ###end

        if (@border)
          xi-=1
          xl+=1
          yi-=1
          yl+=1
        end

        if (tpadding)
          xi -= @padding.left
          xl += @padding.right
          yi -= @padding.top
          yl += @padding.bottom
        end

        # Draw the border.
        if (border = @border)
          battr = sattr(@style.not_nil!.border)
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
            # XXX change type -- BorderType is an enum
            if (border.type == "line")
              if (x == xi)
                ch = '\u250c'; # '┌'
                if (!border.left)
                  if (border.top)
                    ch = '\u2500'; # '─'
                  else
                   next
                  end
                else
                  if (!border.top)
                    ch = '\u2502'; # '│'
                  end
                end
              elsif (x == xl - 1)
                ch = '\u2510'; # '┐'
                if (!border.right)
                  if (border.top)
                    ch = '\u2500'; # '─'
                  else
                    next
                  end
                else
                  if (!border.top)
                    ch = '\u2502'; # '│'
                  end
                end
              else
                ch = '\u2500'; # '─'
              end
            elsif (border.type == "bg")
              ch = border.ch
            end
            if (!border.top && x != xi && x != xl - 1)
              ch = ' '
              if (dattr != cell.attr || ch != cell.char)
                lines[y][x].attr = dattr
                lines[y][x].char = ch
                lines[y].dirty = true
                next
              end
            end
            if (battr != cell.attr || ch != cell.char)
              lines[y][x].attr = battr
              lines[y][x].char = ch ? ch : ' ' # XXX why ch can be nil?
              lines[y].dirty = true
            end
          end
          y = yi + 1
          while(y < yl - 1)
            if (!lines[y]?)
              next
            end
            cell = lines[y][xi]?
            if (cell)
              if (border.left)
                if (border.type == "line")
                  ch = '\u2502'; # '│'
                elsif (border.type == "bg")
                  ch = border.ch
                end
                if (!coords.noleft)
                  if (battr != cell.attr || ch != cell.char)
                    lines[y][xi].attr = battr
                    lines[y][xi].char = ch ? ch : ' '
                    lines[y].dirty = true
                  end
                end
              else
                ch = ' '
                if (dattr != cell.attr || ch != cell.char)
                  lines[y][xi].attr = dattr
                  lines[y][xi].char = ch ? ch : ' '
                  lines[y].dirty = true
                end
              end
            end
            cell = lines[y][xl - 1]?
            if (cell)
              if (border.right)
                # XXX same here, change type
                if (border.type == "line")
                  ch = '\u2502'; # '│'
                elsif (border.type == "bg")
                  ch = border.ch
                end
                if (!coords.noright)
                  if (battr != cell.attr || ch != cell.char)
                    lines[y][xl - 1].attr = battr
                    lines[y][xl - 1].char = ch ? ch : ' '
                    lines[y].dirty = true
                  end
                end
              else
                ch = ' '
                if (dattr != cell.attr || ch != cell.char)
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
            # XXX change type, it's an enum
            if (border.type == "line")
              if (x == xi)
                ch = '\u2514'; # '└'
                if (!border.left)
                  if (border.bottom)
                    ch = '\u2500'; # '─'
                  else
                    next
                  end
                else
                  if (!border.bottom)
                    ch = '\u2502'; # '│'
                  end
                end
              elsif (x == xl - 1)
                ch = '\u2518'; # '┘'
                if (!border.right)
                  if (border.bottom)
                    ch = '\u2500'; # '─'
                  else
                    next
                  end
                else
                  if (!border.bottom)
                    ch = '\u2502'; # '│'
                  end
                end
              else
                ch = '\u2500'; # '─'
              end
            elsif (border.type == "bg")
              ch = border.ch
            end
            if (!border.bottom && x != xi && x != xl - 1)
              ch = ' '
              if (dattr != cell.attr || ch != cell.char)
                lines[y][x].attr = dattr
                lines[y][x].char = ch ? ch : ' '
                lines[y].dirty = true
              end
              next
            end
            if (battr != cell.attr || ch != cell.char)
              lines[y][x].attr = battr
              lines[y][x].char = ch ? ch : ' '
              lines[y].dirty = true
            end
          end
        end

        if (@shadow)
          # right
          y = Math.max(yi + 1, 0)
          while(y<yl)
            if (!lines[y]?)
              break
            end
            x = xl
            while( x < xl + 2)
              if (!lines[y][x]?)
                break
              end
              # D O:
              # lines[y][x].attr = colors.blend(@dattr, lines[y][x].attr)
              # TODO
              #lines[y][x].attr = colors.blend(lines[y][x].attr)
              lines[y][x].attr = 0
              lines[y].dirty = true
              x+=1
            end
            y += 1
          end
          # bottom
          y = yl
          while(y<yl+1)
            if (!lines[y]?)
              break
            end
            (Math.max(xi + 1, 0)...xl).each do |x|
              if (!lines[y][x]?)
                break
              end
              # D O:
              # lines[y][x].attr = colors.blend(@dattr, lines[y][x].attr)
              # TODO
              #lines[y][x].attr = colors.blend(lines[y][x].attr)
              lines[y][x].attr = 0
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

        emit RenderEvent #, coords

        coords
      end
    end
  end
end
