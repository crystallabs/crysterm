abstract class Crysterm::Node
end

module Crysterm
  class Element < Node
    module Position
      def clear_pos(get = false, override = false)
        return if @detached
        lpos = _get_coords(get)
        return unless lpos
        @screen.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, override)
      end

      def _get_coords(get = false, noscroll = false)
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
        # coords
        # v
        # noleft
        # noright
        # notop
        # nobot
        # ppos
        # b
        # Log.trace { yl }

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
        if (thisparent && el && !noscroll && thisparent.is_a? Element)
          ppos = thisparent.lpos

          # The shrink option can cause a stack overflow
          # by calling _get_coords on the child again.
          # if (!get && !thisparent.shrink)
          #   ppos = thisparent._get_coords()
          # end

          if (!ppos)
            return
          end

          # Figure out how to fix base (and cbase) to only
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
              return
            else
              # Is partially covered above.
              notop = true
              v = ppos.yi - yi
              if (@border)
                v -= 1
              end
              if (thisparent.border)
                v += 1
              end
              base += v
              yi += v
            end
          elsif (yl > ppos.yl - b)
            if (yi > ppos.yl - 1 - b)
              # Is below.
              return
            else
              # Is partially covered below.
              nobot = true
              v = yl - ppos.yl
              if (@border)
                v -= 1
              end
              if (thisparent.border)
                v += 1
              end
              yl -= v
            end
          end

          # Shouldn't be necessary.
          # (yi < yl) || raise "No good"
          if (yi >= yl)
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
              xi -= 1
            end
            if (thisparent.border)
              xi += 1
            end
          end
          if (xl > el_lpos.xl)
            xl = el_lpos.xl
            noright = true
            if (@border)
              xl += 1
            end
            if (thisparent.border)
              xl -= 1
            end
          end
          # if (xi > xl)
          #  return
          # end
          if (xi >= xl)
            return
          end
        end

        parent = @parent.not_nil!

        if (@no_overflow && (plp = parent.lpos))
          if (xi < plp.xi + parent.ileft)
            xi = plp.xi + parent.ileft
          end
          if (xl > plp.xl - parent.iright)
            xl = plp.xl - parent.iright
          end
          if (yi < plp.yi + parent.itop)
            yi = plp.yi + parent.itop
          end
          if (yl > plp.yl - parent.ibottom)
            yl = plp.yl - parent.ibottom
          end
        end

        # D O:
        # if (parent.lpos)
        #   parent.lpos._scroll_bottom = Math.max(parent.lpos._scroll_bottom, yl)
        # end
        # p xi, xl, yi, xl

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
        v
      end

      # Positioning

      def _get_width(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent
        unless parent
          raise "Something"
        end
        width = @position.width
        case width
        when String
          if width == "half"
            width = "50%"
          end
          expr = width.split /(?=\+|-)/
          width = expr[0]
          width = width[0...-1].to_f / 100
          width = ((parent.width || 0) * width).to_i
          width += expr[1].to_i if expr[1]?
          return width
        end

        # This is for if the element is being streched or shrunken.
        # Although the width for shrunken elements is calculated
        # in the render function, it may be calculated based on
        # the content width, and the content width is initially
        # decided by the width the element, so it needs to be
        # calculated here.
        if width.nil?
          left = @position.left || 0
          if left.is_a? String
            if (left == "center")
              left = "50%"
            end
            expr = left.split(/(?=\+|-)/)
            left = expr[0]
            left = left[0...-1].to_f / 100
            left = ((parent.width || 0) * left).to_i
            left += expr[1].to_i if expr[1]?
          end
          width = (parent.width || 0) - (@position.right || 0) - left
          if (@screen.auto_padding)
            if ((!@position.left.nil? || @position.right.nil?) && @position.left != "center")
              width -= parent.ileft
            end
            width -= parent.iright
          end
        end

        width
      end

      def width
        _get_width false
      end

      def _get_height(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent
        unless parent
          raise "Something"
        end
        height = @position.height
        case height
        when String
          if height == "half"
            height = "50%"
          end
          expr = height.split /(?=\+|-)/
          height = expr[0]
          height = height[0...-1].to_f / 100
          height = ((parent.height || 0) * height).to_i
          height += expr[1].to_i if expr[1]?
          return height
        end

        # This is for if the element is being streched or shrunken.
        # Although the height for shrunken elements is calculated
        # in the render function, it may be calculated based on
        # the content height, and the content height is initially
        # decided by the height the element, so it needs to be
        # calculated here.
        if height.nil?
          top = @position.top || 0
          if top.is_a? String
            if (top == "center")
              top = "50%"
            end
            expr = top.split(/(?=\+|-)/)
            top = expr[0]
            top = top[0...-1].to_f / 100
            top = ((parent.height || 0) * top).to_i
            top += expr[1].to_i if expr[1]?
          end
          height = (parent.height || 0) - (@position.bottom || 0) - top
          if (@screen.auto_padding)
            if ((!@position.top.nil? || @position.bottom.nil?) && @position.top != "center")
              height -= parent.itop
            end
            height -= parent.ibottom
          end
        end

        height
      end

      def height
        _get_height false
      end

      def _get_left(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent
        unless parent
          raise "Something"
        end

        left = @position.left || 0
        if left.is_a? String
          if left == "center"
            left = "50%"
          end
          expr = left.split /(?=\+|-)/
          left = expr[0]
          left = left[0...-1].to_f / 100
          left = ((parent.width || 0) * left).to_i
          left += expr[1].to_i if expr[1]?
          if @position.left == "center"
            left -= (_get_width(get)) // 2
          end
        end

        if @position.left.nil? && !@position.right.nil?
          return @screen.width - _get_width(get) - _get_right(get)
        end

        if (@screen.auto_padding)
          if ((!@position.left.nil? || @position.right.nil?) && @position.left != "center")
            left += parent.ileft
          end
        end

        left = (parent.aleft || 0) + left
        left
      end

      def aleft
        _get_left false
      end

      def _get_right(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent
        unless parent
          raise "Something"
        end

        if @position.right.nil? && !@position.left.nil?
          right = @screen.width - (_get_left(get) + _get_width(get))
          if (@screen.auto_padding)
            right += parent.iright
          end
        end

        right = (parent.aright || 0) + (@position.right || 0)
        if (@screen.auto_padding)
          right += parent.iright
        end

        right
      end

      def aright
        _get_right false
      end

      def _get_top(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent
        unless parent
          raise "Something"
        end
        top = @position.top || 0
        if top.is_a? String
          if top == "center"
            top = "50%"
          end
          expr = top.split /(?=\+|-)/
          top = expr[0]
          top = top[0...-1].to_f / 100
          top = ((parent.height || 0) * top).to_i
          top += expr[1].to_i if expr[1]?
          if @position.top == "center"
            top -= _get_height(get) // 2
          end
        end

        if @position.top.nil? && !@position.bottom.nil?
          return @screen.height - _get_height(get) - _get_bottom(get)
        end

        if (@screen.auto_padding)
          if ((!@position.top.nil? || @position.bottom.nil?) && @position.top != "center")
            top += parent.itop
          end
        end

        (parent.atop || 0) + top
      end

      def atop
        _get_top false
      end

      def _get_bottom(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent
        unless parent
          raise "Something"
        end

        if @position.bottom.nil? && !@position.top.nil?
          bottom = @screen.height - (_get_top(get) + _get_height(get))
          if (@screen.auto_padding)
            bottom += parent.ibottom
          end
          return bottom
        end

        bottom = (parent.abottom || 0) + (@position.bottom || 0)

        if (@screen.auto_padding)
          bottom += parent.ibottom
        end

        bottom
      end

      def abottom
        _get_bottom false
      end

      def rleft
        aleft - @parent.not_nil!.aleft
      end

      def rright
        aright - @parent.not_nil!.aright
      end

      def rtop
        atop - @parent.not_nil!.atop
      end

      def rbottom
        abottom - @parent.not_nil!.abottom
      end

      def width=(val : Int)
        return if @width == val
        clear_pos
        @position.width = val
        emit ResizeEvent
        val
      end

      def height=(val : Int)
        return if @height == val
        clear_pos
        @position.height = val
        emit ResizeEvent
        val
      end

      def aleft=(val : Int)
        if (val.is_a? String)
          if (val == "center")
            val = @screen.width // 2
            val -= @width // 2
          else
            expr = val.split(/(?=\+|-)/)
            val = expr[0]
            val = val.slice[0...-1].to_f / 100
            val = (@screen.width * val).to_i
            val += expr[1] if expr[1]?
          end
        end
        val -= @parent.not_nil!.aleft
        if (@position.left == val)
          return
        end
        clear_pos
        @position.left = val
        emit MoveEvent
        val
      end

      def aright=(val : Int)
        val -= @parent.not_nil!.aright
        return if (@position.right == val)
        clear_pos
        @position.right = val
        emit MoveEvent
        val
      end

      def atop=(val : Int)
        if (val.is_a? String)
          if (val == "center")
            val = @screen.height // 2
            val -= @height // 2
          else
            expr = val.split(/(?=\+|-)/)
            val = expr[0].to_i
            val = val[0...-1].to_f / 100
            val = (@screen.height * val).to_i
            val += expr[1] if expr[1]?
          end
        end
        val -= @parent.not_nil!.atop
        return if (@position.top == val)
        clear_pos
        @position.top = val
        emit MoveEvent
        val
      end

      def abottom=(val : Int)
        val -= @parent.not_nil!.abottom
        return if (@position.bottom == val)
        clear_pos
        @position.bottom = val
        emit MoveEvent
        val
      end

      def rleft=(val : Int)
        return if (@position.left == val)
        clear_pos
        @position.left = val
        emit MoveEvent
        val
      end

      def rright=(val : Int)
        return if (@position.right == val)
        clear_pos
        @position.right = val
        emit MoveEvent
        val
      end

      def rtop=(val : Int)
        return if (@position.top == val)
        clear_pos
        @position.top = val
        emit MoveEvent
        val
      end

      def rbottom=(val : Int)
        return if (@position.bottom == val)
        clear_pos
        @position.bottom = val
        emit MoveEvent
        val
      end

      def ileft
        (@border ? 1 : 0) + @padding.left
        # return (@border && @border.left ? 1 : 0) + @padding.left
      end

      def itop
        (@border ? 1 : 0) + @padding.top
        # return (@border && @border.top ? 1 : 0) + @padding.top
      end

      def iright
        (@border ? 1 : 0) + @padding.right
        # return (@border && @border.right ? 1 : 0) + @padding.right
      end

      def ibottom
        (@border ? 1 : 0) + @padding.bottom
        # return (@border && @border.bottom ? 1 : 0) + @padding.bottom
      end

      def iwidth
        # return (@border
        #   ? ((@border.left ? 1 : 0) + (@border.right ? 1 : 0)) : 0)
        #   + @padding.left + @padding.right
        (@border ? 2 : 0) + @padding.left + @padding.right
      end

      def iheight
        # return (@border
        #   ? ((@border.top ? 1 : 0) + (@border.bottom ? 1 : 0)) : 0)
        #   + @padding.top + @padding.bottom
        (@border ? 2 : 0) + @padding.top + @padding.bottom
      end

      def _get_shrink_box(xi, xl, yi, yl, get)
        if (@children.size == 0)
          return ShrinkBox.new xi: xi, xl: xi + 1, yi: yi, yl: yi + 1
        end

        # i, el, ret,
        mxi = xi
        mxl = xi + 1
        myi = yi
        myl = yi + 1

        # This is a chicken and egg problem. We need to determine how the children
        # will render in order to determine how this element renders, but it in
        # order to figure out how the children will render, they need to know
        # exactly how their parent renders, so, we can give them what we have so
        # far.
        # _lpos
        if (get)
          _lpos = @lpos
          @lpos = LPos.new xi: xi, xl: xl, yi: yi, yl: yl
          # D O:
          # @shrink = false
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
          if (el.position.left.nil? && !el.position.right.nil?)
            ret.xl = xi + (ret.xl - ret.xi)
            ret.xi = xi
            if (@screen.auto_padding)
              # Maybe just do this no matter what.
              ret.xl += @ileft
              ret.xi += @ileft
            end
          end
          if (el.position.top.nil? && !el.position.bottom.nil?)
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
          @lpos = _lpos
          # D O:
          # @shrink = true
        end

        if (@position.width.nil? && (@position.left.nil? || @position.right.nil?))
          if (@position.left.nil? && !@position.right.nil?)
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
              if is_a? ListTable
                xl -= @padding.left + @padding.right
                xl += @iright
              end
            else
              # D O:
              # xl += @padding.right
              xl += @iright
            end
          end
        end
        if (@position.height.nil? && (@position.top.nil? || @position.bottom.nil?) && (!@scrollable || @_isList))
          # NOTE: Lists get special treatment if they are shrunken - assume they
          # want all list items showing. This is one case we can calculate the
          # height based on items/boxes.
          if (@_isList)
            myi = 0 - @itop
            myl = @items.size + @ibottom
          end
          if (@position.top.nil? && !@position.bottom.nil?)
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

      # Rendition and rendering
      def _get_shrink_content(xi, xl, yi, yl)
        h = @_clines.size
        w = @_clines.mwidth || 1

        if (@position.width.nil? &&
           (@position.left.nil? || @position.right.nil?))
          if (@position.left.nil? && !@position.right.nil?)
            xi = xl - w - @iwidth
          else
            xl = xi + w + @iwidth
          end
        end

        if (@position.height.nil? &&
           (@position.top.nil? || @position.bottom.nil?) &&
           (!@scrollable || @_isList))
          if (@position.top.nil? && !@position.bottom.nil?)
            yi = yl - h - @iheight
          else
            yl = yi + h + @iheight
          end
        end

        ShrinkBox.new xi: xi, xl: xl, yi: yi, yl: yl
      end

      def _get_shrink(xi, xl, yi, yl, get)
        shrink_box = _get_shrink_box(xi, xl, yi, yl, get)
        shrink_content = _get_shrink_content(xi, xl, yi, yl)
        xll = xl
        yll = yl

        # Figure out which one is bigger and use it.
        if (shrink_box.xl - shrink_box.xi > shrink_content.xl - shrink_content.xi)
          xi = shrink_box.xi
          xl = shrink_box.xl
        else
          xi = shrink_content.xi
          xl = shrink_content.xl
        end

        if (shrink_box.yl - shrink_box.yi > shrink_content.yl - shrink_content.yi)
          yi = shrink_box.yi
          yl = shrink_box.yl
        else
          yi = shrink_content.yi
          yl = shrink_content.yl
        end

        # Recenter shrunken elements.
        if (xl < xll && @position.left == "center")
          xll = (xll - xl) // 2
          xi += xll
          xl += xll
        end

        if (yl < yll && @position.top == "center")
          yll = (yll - yl) // 2
          yi += yll
          yl += yll
        end

        return ShrinkBox.new xi: xi, xl: xl, yi: yi, yl: yl
      end

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

      def _get_pos
        pos = @lpos
        pos.try do |pos|
          return pos if !pos.aleft.nil?
          pos.aleft = pos.xi
          pos.atop = pos.yi
          pos.aright = @screen.cols - pos.xl
          pos.abottom = @screen.rows - pos.yl
          pos.width = pos.xl - pos.xi
          pos.height = pos.yl - pos.yi
        end
        pos
      end

      # Relative coordinates as default properties
      def left
        @rleft
      end

      def right
        @rright
      end

      def top
        @rtop
      end

      def bottom
        @rbottom
      end

      def left=(arg)
        @rleft = arg
      end

      def right=(arg)
        @rright = arg
      end

      def top=(arg)
        @rtop = arg
      end

      def bottom=(arg)
        @rbottom = arg
      end
    end
  end
end
