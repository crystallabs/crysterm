module Crysterm
  class Widget
    # Widget's size

    # User-defined width (setter is defined below)
    getter width : Int32 | String | Nil

    # User-defined height (setter is defined below)
    getter height : Int32 | String | Nil

    # Can Crysterm resize the widget if/when needed?
    property? resizable = false

    # Sets widget's total width
    def width=(val)
      return if @width == val
      emit ::Crysterm::Event::Resize
      @width = val
    end

    # Sets widget's total height
    def height=(val)
      return if height == val
      emit ::Crysterm::Event::Resize
      @height = val
    end

    # Returns computed width
    def awidth(get = false)
      oleft = @left
      oright = @right
      width = @width

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      case width
      when String
        if width == "half"
          width = "50%"
        end
        expr = width.split /(?=\+|-)/
        width = expr[0]
        width = width[0...-1].to_f / 100
        width = (((parent.awidth || 0) - (@auto_padding ? parent.iwidth : 0)) * width).to_i
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
        left = oleft || 0
        if left.is_a? String
          if left == "center"
            left = "50%"
          end
          expr = left.split(/(?=\+|-)/)
          left = expr[0]
          left = left[0...-1].to_f / 100
          left = ((parent.awidth || 0) * left).to_i
          left += expr[1].to_i if expr[1]?
        end
        width = (parent.awidth || 0) - (oright || 0) - left

        if @auto_padding
          if (!oleft.nil? || oright.nil?) && oleft != "center"
            width -= parent.ileft
          end
          width -= parent.iright
        end
      end

      width
    end

    # Returns computed height
    def aheight(get = false)
      otop = @top
      obottom = @bottom
      height = @height

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      case height
      when String
        if height == "half"
          height = "50%"
        end
        expr = height.split /(?=\+|-)/
        height = expr[0]
        height = height[0...-1].to_f / 100
        height = (((parent.aheight || 0) - (@auto_padding ? parent.iheight : 0)) * height).to_i
        height += expr[1].to_i if expr[1]?
        return height
      end

      # This is for if the element is being streched or shrunken.
      # Although the height for shrunken elements is calculated
      # in the render function, it may be calculated based on
      # the content height, and the content height is initially
      # decided by the height of the element, so it needs to be
      # calculated here.
      if height.nil?
        top = otop || 0
        if top.is_a? String
          if top == "center"
            top = "50%"
          end
          expr = top.split(/(?=\+|-)/)
          top = expr[0]
          top = top[0...-1].to_f / 100
          top = ((parent.aheight || 0) * top).to_i
          top += expr[1].to_i if expr[1]?
        end
        height = (parent.aheight || 0) - (obottom || 0) - top

        if @auto_padding
          if (!otop.nil? || obottom.nil?) && otop != "center"
            height -= parent.itop
          end
          height -= parent.ibottom
        end
      end

      height
    end

    # Returns minimum widget size based on bounding box
    def _minimal_children_rectangle(xi, xl, yi, yl, get)
      if @children.empty?
        return Rectangle.new xi: xi, xl: xi + 1, yi: yi, yl: yi + 1
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
      if get
        _lpos = @lpos
        @lpos = LPos.new xi: xi, xl: xl, yi: yi, yl: yl
        # D O:
        # @resizable = false
      end

      @children.each do |el|
        ret = el._get_coords(get)

        # D O:
        # Or just (seemed to work, but probably not good):
        # ret = el.lpos || @lpos

        if !ret
          next
        end

        # Since the parent element is shrunk, and the child elements think it's
        # going to take up as much space as possible, an element anchored to the
        # right or bottom will inadvertantly make the parent's shrunken size as
        # large as possible. So, we can just use the height and/or width the of
        # element.
        # D O:
        # if get
        if el.left.nil? && !el.right.nil?
          ret.xl = xi + (ret.xl - ret.xi)
          ret.xi = xi
          # Maybe just do this no matter what.
          ret.xl += ileft
          ret.xi += ileft
        end
        if (el.top.nil? && !el.bottom.nil?)
          ret.yl = yi + (ret.yl - ret.yi)
          ret.yi = yi
          # Maybe just do this no matter what.
          ret.yl += itop
          ret.yi += itop
        end

        if ret.xi < mxi
          mxi = ret.xi
        end
        if ret.xl > mxl
          mxl = ret.xl
        end
        if ret.yi < myi
          myi = ret.yi
        end
        if ret.yl > myl
          myl = ret.yl
        end
      end

      if get
        @lpos = _lpos
        # D O:
        # @resizable = true
      end

      if @width.nil? && (@left.nil? || @right.nil?)
        if @left.nil? && !@right.nil?
          xi = xl - (mxl - mxi)
          if !@auto_padding
            xi -= style.padding.try { |padding| padding.left + padding.right } || 0
          else
            xi -= ileft
          end
        else
          xl = mxl
          if !@auto_padding
            xl += style.padding.try { |padding| padding.left + padding.right } || 0
            # XXX Temporary workaround until we decide to make auto_padding default.
            # See widget-listtable for an example of why this is necessary.
            # XXX Maybe just to this for all this being that this would affect
            # width shrunken normal shrunken lists as well.
            # D O:
            # if @_is_list
            if is_a? ListTable
              xl -= style.padding.try { |padding| padding.left + padding.right } || 0
              xl += iright
            end
          else
            # D O:
            # xl += style.padding.try(&.right) || 0
            xl += iright
          end
        end
      end
      if @height.nil? && (@top.nil? || @bottom.nil?) && (!@scrollable || @_is_list)
        # Note: Lists get special treatment if they are shrunken - assume they
        # want all list items showing. This is one case we can calculate the
        # height based on items/boxes.
        if @_is_list
          myi = 0 - itop
          myl = @items.size + ibottom
        end
        if @top.nil? && !@bottom.nil?
          yi = yl - (myl - myi)
          if !@auto_padding
            yi -= style.padding.try { |padding| padding.top + padding.bottom } || 0
          else
            yi -= itop
          end
        else
          yl = myl
          if !@auto_padding
            yl += style.padding.try { |padding| padding.top + padding.bottom } || 0
          else
            yl += ibottom
          end
        end
      end

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end

    # Returns minimum widget size based on content.
    #
    # NOTE For this function to return intended results, the widget whose contents
    # are being examined should not have a particular `#align=` value.
    # If `#align=` is used, the alignment method will align it by padding with
    # spaces, and in turn make the minimal size returned from this method be the
    # maximum/full size of the surrounding box.
    def _minimal_content_rectangle(xi, xl, yi, yl)
      h = @_clines.size
      w = @_clines.max_width || 0

      # The extra IFs which are commented appear unnecessary.
      # If a person sets resizable: true, this is expected to happen
      # no matter what; not only if other coordinates are also left empty.

      if @width.nil? && (@left.nil? || @right.nil?)
        if @left.nil? && !@right.nil?
          xi = xl - w - iwidth
        else
          xl = xi + w + iwidth
        end
      end
      # end

      if (@height.nil? && (@top.nil? || @bottom.nil?) &&
         (!@scrollable || @_is_list))
        if (@top.nil? && !@bottom.nil?)
          yi = yl - h - iheight # (iheight == 1 ? 0 : iheight)
        else
          yl = yi + h + iheight # (iheight == 1 ? 0 : iheight)
        end
      end

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end

    # Returns minimum widget size
    def _minimal_rectangle(xi, xl, yi, yl, get)
      minimal_children_rectangle = _minimal_children_rectangle(xi, xl, yi, yl, get)
      minimal_content_rectangle = _minimal_content_rectangle(xi, xl, yi, yl)
      xll = xl
      yll = yl

      # Figure out which one is bigger and use it.
      if (minimal_children_rectangle.xl - minimal_children_rectangle.xi > minimal_content_rectangle.xl - minimal_content_rectangle.xi)
        xi = minimal_children_rectangle.xi
        xl = minimal_children_rectangle.xl
      else
        xi = minimal_content_rectangle.xi
        xl = minimal_content_rectangle.xl
      end

      if (minimal_children_rectangle.yl - minimal_children_rectangle.yi > minimal_content_rectangle.yl - minimal_content_rectangle.yi)
        yi = minimal_children_rectangle.yi
        yl = minimal_children_rectangle.yl
      else
        yi = minimal_content_rectangle.yi
        yl = minimal_content_rectangle.yl
      end

      # Recenter shrunken elements.
      if (xl < xll && @left == "center")
        xll = (xll - xl) // 2
        xi += xll
        xl += xll
      end

      if (yl < yll && @top == "center")
        yll = (yll - yl) // 2
        yi += yll
        yl += yll
      end

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end
  end
end
