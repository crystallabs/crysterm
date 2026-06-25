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
      mark_dirty
    end

    # Sets widget's total height
    def height=(val)
      return if height == val
      emit ::Crysterm::Event::Resize
      @height = val
      mark_dirty
    end

    # CSS `min-width`/`max-width`/`min-height`/`max-height` size constraints, in
    # cells (`nil` = unconstrained). `awidth`/`aheight` clamp the *used* size to
    # `[min, max]` — so they cap a `width: "100%"` or stretched widget and raise a
    # too-small one, exactly like CSS, and `min` wins when it exceeds `max`. Set
    # from a stylesheet by `CSS::Geometry`; settable directly too.
    getter min_width : Int32? = nil
    getter max_width : Int32? = nil
    getter min_height : Int32? = nil
    getter max_height : Int32? = nil

    {% for dim in %w[min_width max_width min_height max_height] %}
      def {{dim.id}}=(val : Int32?)
        return if @{{dim.id}} == val
        @{{dim.id}} = val
        mark_dirty
      end
    {% end %}

    # Clamps a computed width to the `[min_width, max_width]` constraints (a
    # no-op when both are `nil`). `max` is applied before `min` so `min` wins a
    # `min > max` conflict, per CSS.
    private def clamp_awidth(w : Int32) : Int32
      if max = @max_width
        w = Math.min(w, max)
      end
      if min = @min_width
        w = Math.max(w, min)
      end
      w
    end

    # :ditto: for height.
    private def clamp_aheight(h : Int32) : Int32
      if max = @max_height
        h = Math.min(h, max)
      end
      if min = @min_height
        h = Math.max(h, min)
      end
      h
    end

    # Returns computed width
    def awidth(get = false)
      oleft = @left
      oright = @right
      width = @width

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      case width
      when String
        # A percentage is of the parent's *content* area (inside its border/
        # padding), like CSS `width: 100%` — so `width: "100%"` fills the
        # interior of a bordered parent rather than overrunning it. For a parent
        # with no insets (e.g. a screen child) this is unchanged. The matching
        # `aleft` adds the parent's near inset, so a `left: 0` child sits just
        # inside the border and a `"100%"` child reaches exactly the far inset.
        return clamp_awidth(resolve_dimension(width, (parent.awidth || 0) - parent.ileft - parent.iright, "half"))
      end

      # This is for if the element is being stretched or shrunken.
      # Although the width for shrunken elements is calculated
      # in the render function, it may be calculated based on
      # the content width, and the content width is initially
      # decided by the width the element, so it needs to be
      # calculated here.
      if width.nil?
        # `parent.awidth` climbs the whole ancestor chain (or, under `get`, reads
        # the parent's stored `LPos`). This branch needs it for both the string
        # `resolve_dimension` base and the width subtraction; calling it twice
        # made a chain of nil-width + string-left widgets recompute the ancestors
        # O(2^depth) times (a centered, auto-width box is a completely ordinary
        # config). Computing it once collapses that to O(depth). It stays *inside*
        # this branch so an integer-width widget still never walks the chain.
        pw = parent.awidth || 0
        left = oleft || 0
        if left.is_a? String
          left = resolve_dimension(left, pw, "center")
        end
        width = pw - (oright || 0) - left

        if applies_near_offset?(oleft, oright)
          width -= parent.ileft
        end
        width -= parent.iright
      end

      width.is_a?(Int32) ? clamp_awidth(width) : width
    end

    # Returns computed height
    def aheight(get = false)
      otop = @top
      obottom = @bottom
      height = @height

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      case height
      when String
        # Percentage of the parent's *content* height (inside border/padding);
        # see `awidth` for the rationale (CSS-like, fills the interior).
        return clamp_aheight(resolve_dimension(height, (parent.aheight || 0) - parent.itop - parent.ibottom, "half"))
      end

      # This is for if the element is being stretched or shrunken.
      # Although the height for shrunken elements is calculated
      # in the render function, it may be calculated based on
      # the content height, and the content height is initially
      # decided by the height of the element, so it needs to be
      # calculated here.
      if height.nil?
        # See `awidth`: one `parent.aheight` shared between the string base and
        # the height subtraction, kept inside this branch so a fixed-height
        # widget still never recurses. O(2^depth) → O(depth).
        ph = parent.aheight || 0
        top = otop || 0
        if top.is_a? String
          top = resolve_dimension(top, ph, "center")
        end
        height = ph - (obottom || 0) - top

        if applies_near_offset?(otop, obottom)
          height -= parent.itop
        end
        height -= parent.ibottom
      end

      height.is_a?(Int32) ? clamp_aheight(height) : height
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
        # right or bottom will inadvertently make the parent's shrunken size as
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
        if el.top.nil? && !el.bottom.nil?
          ret.yl = yi + (ret.yl - ret.yi)
          ret.yi = yi
          # Maybe just do this no matter what.
          ret.yl += itop
          ret.yi += itop
        end

        mxi = Math.min(mxi, ret.xi)
        mxl = Math.max(mxl, ret.xl)
        myi = Math.min(myi, ret.yi)
        myl = Math.max(myl, ret.yl)
      end

      if get
        @lpos = _lpos
        # D O:
        # @resizable = true
      end

      if @width.nil? && (@left.nil? || @right.nil?)
        if @left.nil? && !@right.nil?
          xi = xl - (mxl - mxi)
          xi -= style.padding.try { |padding| padding.left + padding.right } || 0
          xi -= mwidth # reserve room for the margin _get_coords insets back out
        else
          xl = mxl
          # D O:
          # xl += style.padding.try(&.right) || 0
          xl += iright
          xl += mwidth # reserve room for the margin _get_coords insets back out
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
          yi -= itop
          yi -= mheight # reserve room for the margin _get_coords insets back out
        else
          yl = myl
          yl += ibottom
          yl += mheight # reserve room for the margin _get_coords insets back out
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

      # `mwidth`/`mheight` reserve room for the element's own margin, which
      # `_get_coords` insets back out of the resolved rectangle. Without this a
      # shrunk-to-content widget would have its content clipped by the margin.
      if @width.nil? && (@left.nil? || @right.nil?)
        if @left.nil? && !@right.nil?
          xi = xl - w - iwidth - mwidth
        else
          xl = xi + w + iwidth + mwidth
        end
      end
      # end

      if @height.nil? && (@top.nil? || @bottom.nil?) &&
         (!@scrollable || @_is_list)
        if @top.nil? && !@bottom.nil?
          yi = yl - h - iheight - mheight # (iheight == 1 ? 0 : iheight)
        else
          yl = yi + h + iheight + mheight # (iheight == 1 ? 0 : iheight)
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
      if minimal_children_rectangle.xl - minimal_children_rectangle.xi > minimal_content_rectangle.xl - minimal_content_rectangle.xi
        xi = minimal_children_rectangle.xi
        xl = minimal_children_rectangle.xl
      else
        xi = minimal_content_rectangle.xi
        xl = minimal_content_rectangle.xl
      end

      if minimal_children_rectangle.yl - minimal_children_rectangle.yi > minimal_content_rectangle.yl - minimal_content_rectangle.yi
        yi = minimal_children_rectangle.yi
        yl = minimal_children_rectangle.yl
      else
        yi = minimal_content_rectangle.yi
        yl = minimal_content_rectangle.yl
      end

      # Recenter shrunken elements.
      if xl < xll && @left == "center"
        xll = (xll - xl) // 2
        xi += xll
        xl += xll
      end

      if yl < yll && @top == "center"
        yll = (yll - yl) // 2
        yi += yll
        yl += yll
      end

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end
  end
end
