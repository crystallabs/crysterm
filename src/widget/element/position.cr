struct Int32
  def any?
    self != 0
  end
end

abstract class Crysterm::Widget::Node
end

module Crysterm::Widget
  class Element < Node
    module Position

      def clear_pos(get=false, override=false)
        return if @detached
        lpos = _get_coords(get)
        return unless lpos
        @screen.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, override)
      end

      # Positioning

      def _get_width(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent
        width = @position.width || 0
        case width
        when String
          if width == "half"
            width = "50%"
          end
          expr = width.split /(?=\+|-)/
          width = expr[0]
          width = width[0...-1].to_i / 100
          width = (parent.width * width).to_i
          width += expr[1].to_i # Can be empty/nil XXX. Same note below
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
            left = left[0...-1].to_i / 100
            left = (parent.width * left).to_i
            left += expr[1].to_i
          end
          width = parent.width - (@position.right || 0) - left
          if (@screen.auto_padding)
            if ((@position.left.any? || @position.right.nil?) && @position.left != "center")
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
        height = @position.height
        case height
        when String
          if height == "half"
            height = "50%"
          end
          expr = height.split /(?=\+|-)/
          height = expr[0]
          height = height[0...-1].to_i / 100
          height = (parent.height * height).to_i
          height += expr[1].to_i
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
            top = top[0...-1].to_i / 100; # wt
            top = (parent.height * top).to_i
            top += expr[1].to_i
          end
          height = parent.height - (@position.bottom || 0) - top
          if (@screen.auto_padding)
            if ((@position.top.any? || @position.bottom.nil?) && @position.top != "center")
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

        left = @position.left || 0
        case left
        when String
          if left == "half"
            left = "50%"
          end
          expr = left.split /(?=\+|-)/
          left = expr[0]
          left = left[0...-1].to_i / 100
          left = (parent.width * left).to_i
          left += expr[1].to_i
          if @position.left == "center"
            left -= (_get_width(get)) // 2
          end
        end

        if @position.left.nil? && @position.right.any?
          return @screen.width - _get_width(get) - _get_right(get)
        end

        if (@screen.auto_padding)
          if ((@position.left.any? || @position.right.nil?) && @position.left != "center")
            left += parent.ileft
          end
        end

        (parent.aleft||0) + left
      end

      def aleft
        _get_left false
      end

      def _get_right(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent

        if @position.right.nil? && @position.left.any?
          right = @screen.width - (_get_left(get) + _get_width(get))
          if (@screen.auto_padding)
            right += parent.iright
          end
        end

        right = (parent.aright||0) + (@position.right||0)
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
        top = @position.top || 0
        case top
        when String
          if top == "center"
            top = "50%"
          end
          expr = top.split /(?=\+|-)/
          top = expr[0]
          top = top[0...-1].to_i / 100
          top = (parent.height * top).to_i
          top += expr[1].to_i
          if top == "center"
            top -= _get_height(get) // 2
          end
        end

        if @position.top.nil? && @position.bottom.any?
          return @screen.height - _get_height(get) - _get_bottom(get)
        end

        if (@screen.auto_padding)
          if((@position.top.any? || @position.bottom.nil?) && @position.top != "center")
            top += parent.itop
          end
        end

        (parent.atop||0) + top
      end

      def atop
        _get_top false
      end

      def _get_bottom(get)
        raise "No parent" unless parent = @parent
        parent = get ? parent._get_pos : parent

        if @position.bottom.nil? && @position.top.any?
          bottom = @screen.height - (_get_top(get) + _get_height(get))
          if (@screen.auto_padding)
            bottom += parent.ibottom
          end
          return bottom
        end

        bottom = (parent.abottom||0) + (@position.bottom||0)

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
        this.emit ResizeEvent
        val
      end
      def height=(val)
        return if @height == val
        clear_pos
        @position.height = val
        this.emit ResizeEvent
        val
      end

      def aleft=(val)
        if (val.is_a? String)
          if (val == "center")
            val = @screen.width // 2
            val -= @width // 2
          else
            expr = val.split(/(?=\+|-)/)
            val = expr[0]
            val = val.slice[0...-1].to_i / 100
            val = (@screen.width * val).to_i
            val += expr[1]
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

      def aright=(val)
        val -= @parent.not_nil!.aright
        return if (@position.right == val)
        clear_pos
        @position.right = val
        emit MoveEvent
        val
      end

      def atop=(val)
        if (val.is_a? String)
          if (val == "center")
            val = @screen.height // 2
            val -= @height // 2
          else
            expr = val.split(/(?=\+|-)/)
            val = expr[0].to_i
            val = val[0...-1].to_i / 100
            val = (@screen.height * val).to_i
            val += expr[1]
          end
        end
        val -= @parent.not_nil!.atop
        return if (@position.top == val)
        clear_pos
        @position.top = val
        emit MoveEvent
        val
      end

      def abottom=(val)
        val -= @parent.not_nil!.abottom
        return if (@position.bottom == val)
        clear_pos
        @position.bottom = val
        emit MoveEvent
        val
      end

      # TODO add restrictions to all these args up and below
      def rleft=(val : Int)
        return if (@position.left == val)
        clear_pos
        @position.left = val
        emit MoveEvent
        val
      end

      def rright=(val)
        return if (@position.right == val)
        clear_pos
        @position.right = val
        emit MoveEvent
        val
      end

      def rtop=(val)
        return if (@position.top == val)
        clear_pos
        @position.top = val
        emit MoveEvent
        val
      end

      def rbottom=(val)
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

      def tpadding
        @padding.left + @padding.top + @padding.right + @padding.bottom
      end

      # Rendition and rendering
      def _get_shrink_content(xi, xl, yi, yl)
        h = @_clines.size
        w = @_clines.mwidth || 1

        if (@position.width.nil?  &&
           (@position.left.nil?  || @position.right.nil?))

          if (@position.left.nil? && @position.right.any?)
            xi = xl - w - @iwidth
          else
            xl = xi + w + @iwidth
          end
        end

        if (@position.height.nil?  &&
           (@position.top.nil?  || @position.bottom.nil?) &&
           (!@scrollable || @_isList))

          if (@position.top.nil? && @position.bottom.any?)
            yi = yl - h - @iheight
          else
            yl = yi + h + @iheight
          end
        end

        ShrinkBox.new xi: xi, xl: xl, yi: yi, yl: yl
      end

      def _get_shrink(xi, xl, yi, yl, get)
        shrinkBox = _get_shrink_box(xi, xl, yi, yl, get)
        shrinkContent = _get_shrink_content(xi, xl, yi, yl)
        xll = xl
        yll = yl

        # Figure out which one is bigger and use it.
        if (shrinkBox.xl - shrinkBox.xi > shrinkContent.xl - shrinkContent.xi)
          xi = shrinkBox.xi
          xl = shrinkBox.xl
        else
          xi = shrinkContent.xi
          xl = shrinkContent.xl
        end

        if (shrinkBox.yl - shrinkBox.yi > shrinkContent.yl - shrinkContent.yi)
          yi = shrinkBox.yi
          yl = shrinkBox.yl
        else
          yi = shrinkContent.yi
          yl = shrinkContent.yl
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
          return pos if pos.aleft.any?
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
      def left() @rleft end
      def right() @rright end
      def top() @rtop end
      def bottom() @rbottom end

      def left=(arg) @rleft=arg end
      def right=(arg) @rright=arg end
      def top=(arg) @rtop=arg end
      def bottom=(arg) @rbottom=arg end
    end
  end
end
