module Crysterm
  class Widget < Crysterm::Object
    # module Rectangles
    # Returns minimum widget size based on bounding box
    def _get_minimal_children_rectangle(xi, xl, yi, yl, get)
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
      if (get)
        _lpos = @lpos
        @lpos = LPos.new xi: xi, xl: xl, yi: yi, yl: yl
        # D O:
        # @resizable = false
      end

      # @children.each_with_index do |el, _|
      @children.each do |el|
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
          if @auto_padding
            # Maybe just do this no matter what.
            ret.xl += ileft
            ret.xi += ileft
          end
        end
        if (el.position.top.nil? && !el.position.bottom.nil?)
          ret.yl = yi + (ret.yl - ret.yi)
          ret.yi = yi
          if @auto_padding
            # Maybe just do this no matter what.
            ret.yl += itop
            ret.yi += itop
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
        # @resizable = true
      end

      if (@position.width.nil? && (@position.left.nil? || @position.right.nil?))
        if (@position.left.nil? && !@position.right.nil?)
          xi = xl - (mxl - mxi)
          if (!@auto_padding)
            xi -= @padding.left + @padding.right
          else
            xi -= ileft
          end
        else
          xl = mxl
          if (!@auto_padding)
            xl += @padding.left + @padding.right
            # XXX Temporary workaround until we decide to make auto_padding default.
            # See widget-listtable for an example of why this is necessary.
            # XXX Maybe just to this for all this being that this would affect
            # width shrunken normal shrunken lists as well.
            # D O:
            # if @_is_list
            if is_a? ListTable
              xl -= @padding.left + @padding.right
              xl += iright
            end
          else
            # D O:
            # xl += @padding.right
            xl += iright
          end
        end
      end
      if (@position.height.nil? && (@position.top.nil? || @position.bottom.nil?) && (!@scrollable || @_is_list))
        # Note: Lists get special treatment if they are shrunken - assume they
        # want all list items showing. This is one case we can calculate the
        # height based on items/boxes.
        if @_is_list
          myi = 0 - itop
          myl = @items.size + ibottom
        end
        if (@position.top.nil? && !@position.bottom.nil?)
          yi = yl - (myl - myi)
          if (!@auto_padding)
            yi -= @padding.top + @padding.bottom
          else
            yi -= itop
          end
        else
          yl = myl
          if (!@auto_padding)
            yl += @padding.top + @padding.bottom
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
    def _get_minimal_content_rectangle(xi, xl, yi, yl)
      h = @_clines.size
      w = @_clines.max_width || 0

      # The extra IFs which are commented appear unnecessary.
      # If a person sets resizable: true, this is expected to happen
      # no matter what; not only if other coordinates are also left empty.

      if (@position.width.nil? && (@position.left.nil? || @position.right.nil?))
        if @position.left.nil? && !@position.right.nil?
          xi = xl - w - iwidth
        else
          xl = xi + w + iwidth
        end
      end
      # end

      if (@position.height.nil? && (@position.top.nil? || @position.bottom.nil?) &&
         (!@scrollable || @_is_list))
        if (@position.top.nil? && !@position.bottom.nil?)
          yi = yl - h - iheight # (iheight == 1 ? 0 : iheight)
        else
          yl = yi + h + iheight # (iheight == 1 ? 0 : iheight)
        end
      end

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end

    # Returns minimum widget size
    def _get_minimal_rectangle(xi, xl, yi, yl, get)
      minimal_children_rectangle = _get_minimal_children_rectangle(xi, xl, yi, yl, get)
      minimal_content_rectangle = _get_minimal_content_rectangle(xi, xl, yi, yl)
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

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end
    # end
  end
end
