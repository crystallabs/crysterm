module Crysterm
  class Widget
    # Takes screenshot of a widget.
    #
    # Does not include decorations, but content only.
    #
    # It is possible to influence the coordinates that will be
    # screenshot with the 4 arguments to the function, but they
    # are not intuitive.
    def screenshot(xi = nil, xl = nil, yi = nil, yl = nil)
      lpos = @lpos
      return unless lpos

      xi = lpos.xi + ileft + (xi || 0)
      if xl
        xl = lpos.xi + ileft + (xl || 0)
      else
        xl = lpos.xl - iright
      end

      yi = lpos.yi + itop + (yi || 0)
      if yl
        yl = lpos.yi + itop + (yl || 0)
      else
        yl = lpos.yl - ibottom
      end

      screen.screenshot xi, xl, yi, yl
    end

    # Takes screenshot of a widget in a more convenient way than `#screenshot`.
    #
    # To take a screenshot of entire widget, just call `#snapshot`.
    # To avoid decorations, use `#snapshot(false)`.
    #
    # To additionally fine-tune the region, pass 'd' values. For example to enlarge the area of
    # screenshot by 1 cell on the left, 2 cells on the right, 3 on top, and 4 on the bottom, call:
    #
    # ```
    # snapshot(true, -1, 2, -3, 4)
    # ```
    #
    # This is hopefully better than the equivalent you would have to use with `#screenshot`:
    #
    # ```
    # screenshot(-ileft - 1, width + iright + 2, -itop - 3, height + ibottom + 4)
    # ```
    def snapshot(include_decorations = true, dxi = 0, dxl = 0, dyi = 0, dyl = 0)
      lpos = @lpos
      return unless lpos

      xi = lpos.xi + (include_decorations ? 0 : ileft) + dxi
      xl = lpos.xl + (include_decorations ? 0 : -iright) + dxl

      yi = lpos.yi + (include_decorations ? 0 : itop) + dyi
      yl = lpos.yl + (include_decorations ? 0 : -ibottom) + dyl

      screen.screenshot xi, xl, yi, yl
    end
  end
end
