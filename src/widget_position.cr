module Crysterm
  class Widget
    # Methods related to 3D position (X, Y, and Z which is the stacking / render order)

    # User-defined left
    getter left : Int32 | String | Nil

    # User-defined top
    getter top : Int32 | String | Nil

    # User-defined right
    getter right : Int32 | Nil

    # User-defined bottom
    getter bottom : Int32 | Nil

    # User-defined width (setter is defined below)
    getter width : Int32 | String | Nil

    # User-defined height (setter is defined below)
    getter height : Int32 | String | Nil

    # Can Crysterm resize the widget if/when needed?
    property? resizable = false

    # Widget's render index / order of rendering.
    property index = -1

    # Whether the widget position is fixed even in presence of scroll?
    # (Primary use in widget labels, which are always e.g. on top-left)
    private property? fixed = false

    # Sets Widget's `@left`
    def left=(val)
      return if @left == val
      emit ::Crysterm::Event::Move
      @left = val
    end

    # Sets Widget's `@right`
    def right=(val)
      return if @right == val
      emit ::Crysterm::Event::Move
      @right = val
    end

    # Sets Widget's `@top`
    def top=(val)
      return if @top == val
      emit ::Crysterm::Event::Move
      @top = val
    end

    # Sets Widget's `@bottom`
    def bottom=(val)
      return if @bottom == val
      emit ::Crysterm::Event::Move
      @bottom = val
    end

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

    # Returns computed absolute left position
    def aleft(get = false)
      # Original left
      oleft = @left
      oright = @right

      if oleft.nil? && !oright.nil?
        return screen.awidth - awidth(get) - aright(get)
      end

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      left = oleft || 0
      if left.is_a? String
        if left == "center"
          left = "50%"
        end
        expr = left.split /(?=\+|-)/
        left = expr[0]
        left = left[0...-1].to_f / 100
        left = ((parent.awidth || 0) * left).to_i
        left += expr[1].to_i if expr[1]?
        if oleft == "center"
          left -= (awidth(get)) // 2
        end
      end

      if @auto_padding
        if (!oleft.nil? || oright.nil?) && oleft != "center"
          left += parent.ileft
        end
      end

      (parent.aleft || 0) + left
    end

    # Returns computed absolute top position
    def atop(get = false)
      otop = @top
      obottom = @bottom

      if otop.nil? && !obottom.nil?
        return screen.aheight - aheight(get) - abottom(get)
      end

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      top = otop || 0
      if top.is_a? String
        if top == "center"
          top = "50%"
        end
        expr = top.split /(?=\+|-)/
        top = expr[0]
        top = top[0...-1].to_f / 100
        top = ((parent.aheight || 0) * top).to_i
        top += expr[1].to_i if expr[1]?
        if otop == "center"
          top -= aheight(get) // 2
        end
      end

      if @auto_padding
        if (!otop.nil? || obottom.nil?) && otop != "center"
          top += parent.itop
        end
      end

      (parent.atop || 0) + top
    end

    # Returns computed absolute right position
    def aright(get = false)
      oleft = @left
      oright = @right
      auto_padding = @auto_padding

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      if oright.nil? && !oleft.nil?
        right = screen.awidth - (aleft(get) + awidth(get))
        if auto_padding
          right += parent.iright
        end
      end

      right = (parent.aright || 0) + (oright || 0)
      if auto_padding
        right += parent.iright
      end

      right
    end

    # Returns computed absolute bottom position
    def abottom(get = false)
      otop = @top
      obottom = @bottom
      auto_padding = @auto_padding

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      if obottom.nil? && !otop.nil?
        bottom = screen.aheight - atop(get) - aheight(get)
        if auto_padding
          bottom += parent.ibottom
        end
        return bottom
      end

      bottom = (parent.abottom || 0) + (obottom || 0)

      if auto_padding
        bottom += parent.ibottom
      end

      bottom
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

    # Returns computed relative left position
    def rleft
      (aleft || 0) - (parent_or_screen.aleft || 0)
    end

    # Returns computed relative top position
    def rtop
      (atop || 0) - (parent_or_screen.atop || 0)
    end

    # Returns computed relative right position
    def rright
      (aright || 0) - (parent_or_screen.aright || 0)
    end

    # Returns computed relative bottom position
    def rbottom
      (abottom || 0) - (parent_or_screen.abottom || 0)
    end

    # Returns computed content offset from left
    def ileft
      (style.border.try(&.left) || 0) + (style.padding.try(&.left) || 0)
    end

    # Returns computed content offset from top
    def itop
      (style.border.try(&.top) || 0) + (style.padding.try(&.top) || 0)
    end

    # Returns computed content offset from right
    def iright
      (style.border.try(&.right) || 0) + (style.padding.try(&.right) || 0)
    end

    # Returns computed content offset from bottom
    def ibottom
      (style.border.try(&.bottom) || 0) + (style.padding.try(&.bottom) || 0)
    end

    # Returns computed inner (content) width
    def iwidth
      # return (style.border
      #   ? ((style.border.left ? 1 : 0) + (style.border.right ? 1 : 0)) : 0)
      #   + style.padding.left + style.padding.right
      (style.border.try { |border| border.left + border.right } || 0) +
        (style.padding.try { |padding| padding.left + padding.right } || 0)
    end

    # Returns computed inner (content) height
    def iheight
      # return (style.border
      #   ? ((style.border.top ? 1 : 0) + (style.border.bottom ? 1 : 0)) : 0)
      #   + style.padding.top + style.padding.bottom
      (style.border.try { |border| border.top + border.bottom } || 0) +
        (style.padding.try { |padding| padding.top + padding.bottom } || 0)
    end

    # XXX Disabled because nothing uses these at the moment, and also they
    # are not resize-safe. Widget will remain in the old/unresized position
    # after a resize.
    #
    # def aleft=(val)
    #  if val.is_a? String
    #    if (val == "center")
    #      val = screen.awidth // 2
    #      val -= @width // 2
    #    else
    #      expr = val.split(/(?=\+|-)/)
    #      val = expr[0]
    #      val = val.slice[0...-1].to_f / 100
    #      val = (screen.awidth * val).to_i
    #      val += expr[1] if expr[1]?
    #    end
    #  end
    #  val -= parent_or_screen.aleft
    #  if @left == val
    #    return
    #  end
    #  clear_last_rendered_position
    #  @left = val
    #  emit ::Crysterm::Event::Move
    #  val
    # end

    # def aright=(val)
    #  val -= parent_or_screen.aright
    #  return if @right == val
    #  clear_last_rendered_position
    #  @right = val
    #  emit ::Crysterm::Event::Move
    #  val
    # end

    # def atop=(val)
    #  if val.is_a? String
    #    if val == "center"
    #      val = screen.aheight // 2
    #      val -= height // 2
    #    else
    #      expr = val.split(/(?=\+|-)/)
    #      val = expr[0].to_i
    #      val = val[0...-1].to_f / 100
    #      val = (screen.aheight * val).to_i
    #      val += expr[1] if expr[1]?
    #    end
    #  end
    #  val -= parent_or_screen.atop
    #  return if @top == val
    #  clear_last_rendered_position
    #  @top = val
    #  emit ::Crysterm::Event::Move
    #  val
    # end

    # def abottom=(val)
    #  val -= parent_or_screen.abottom
    #  return if @bottom == val
    #  clear_last_rendered_position
    #  @bottom = val
    #  emit ::Crysterm::Event::Move
    #  val
    # end

    # Clears area/position of widget's last render
    def clear_last_rendered_position(get = false, override = false)
      return unless @screen
      lpos = _get_coords(get)
      return unless lpos
      screen.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, override)
    end

    def _get_coords(get = false, noscroll = false)
      unless style.visible?
        return
      end

      # D O:
      # if @parent._rendering
      #   get = true
      # end

      xi = aleft(get)
      xl = xi + awidth(get)
      yi = atop(get)
      yl = yi + aheight(get)

      # Informs us which side is partly hidden due to being enclosed in a
      # parent (and potentially scrollable) element. Will be set/computed later.
      no_left = false
      no_right = false
      no_top = false
      no_bottom = false

      base = @child_base
      el = self
      fixed = @fixed

      # Attempt to resize the element based on the
      # size of the content and child elements.
      if resizable?
        coords = _minimal_rectangle(xi, xl, yi, yl, get)
        xi = coords.xi
        xl = coords.xl
        yi = coords.yi
        yl = coords.yl
      end

      # Find a scrollable ancestor if we have one.
      while el = el.parent
        if el.scrollable?
          if fixed
            fixed = false
            next
          end
          break
        end
      end

      # Check to make sure we're visible and
      # inside of the visible scroll area.
      # Note: Lists have a property where only
      # the list items are obfuscated.

      # Old way of doing things, this would not render right if a shrunken element
      # with lots of boxes in it was within a scrollable element.
      # See: $ c test/widget-shrink-fail.cr
      # scrollable_parent = @parent

      # First/closest scrollable parent
      scrollable_parent = el

      # Using scrollable_parent && el here to restrict both to non-nil
      if scrollable_parent && !noscroll
        # This is an intentional assignment:
        unless scrollable_parent_lpos = scrollable_parent.lpos
          raise "Unexpected that scrollable_parent.lpos == nil"
        end

        # D O:
        # The resizable option can cause a stack overflow
        # by calling _get_coords on the child again.
        # if !get && !scrollable_parent.resizable?
        #   scrollable_parent_lpos = scrollable_parent._get_coords()
        # end

        # O: TODO Figure out how to fix base (and cbase) to only
        # take into account the *parent's* padding.
        yi -= scrollable_parent_lpos.base
        yl -= scrollable_parent_lpos.base

        b = scrollable_parent.style.border.try(&.top) || 0
        # Old code for the above was:
        # b = scrollable_parent.border ? 1 : 0
        # I hope this was referring to the top border and that the replacement/improvement
        # to support variable border width was correct.

        # D O:
        # XXX
        # Fixes non-`fixed` labels to work with scrolling (they're ON the border):
        # if @left < 0 || @right < 0 || @top < 0 || @bottom < 0
        if @_label
          b = 0
        end

        if yi < scrollable_parent_lpos.yi + b
          if yl - 1 < scrollable_parent_lpos.yi + b
            # Is above.
            return
          else
            # Is partially covered above.
            no_top = true
            v = scrollable_parent_lpos.yi - yi
            style.border.try do |border|
              v -= border.top
            end
            scrollable_parent.style.border.try do |border|
              v += border.top
            end
            base += v
            yi += v
          end
        elsif yl > scrollable_parent_lpos.yl - b
          if yi > scrollable_parent_lpos.yl - 1 - b
            # Is below.
            return
          else
            # Is partially covered below.
            no_bottom = true
            v = yl - scrollable_parent_lpos.yl
            style.border.try do |border|
              v -= border.bottom
            end
            scrollable_parent.style.border.try do |border|
              v += border.bottom
            end
            yl -= v
          end
        end

        # D O:
        # Shouldn't be necessary.
        # (yi < yl) || raise "No good"
        if yi >= yl
          return
        end

        # Could allow overlapping stuff in scrolling elements
        # if we cleared the pending buffer before every draw.
        if xi < scrollable_parent_lpos.xi
          xi = scrollable_parent_lpos.xi
          no_left = true
          style.border.try do |border|
            xi -= border.left
          end
          scrollable_parent.style.border.try do |border|
            xi += border.left
          end
        end
        if xl > scrollable_parent_lpos.xl
          xl = scrollable_parent_lpos.xl
          no_right = true
          style.border.try do |border|
            xl += border.right
          end
          scrollable_parent.style.border.try do |border|
            xl -= border.right
          end
        end
        # D O:
        # if xi > xl
        #  return
        # end
        if xi >= xl
          return
        end
      end

      parent = parent_or_screen

      # NOTE `plp=parent.lpos` assignment below-right is intentional:
      if (parent.overflow == Overflow::ShrinkWidget) && (plp = parent.lpos)
        if xi < plp.xi + parent.ileft
          xi = plp.xi + parent.ileft
        end
        if xl > plp.xl - parent.iright
          xl = plp.xl - parent.iright
        end
        if yi < plp.yi + parent.itop
          yi = plp.yi + parent.itop
        end
        if yl > plp.yl - parent.ibottom
          yl = plp.yl - parent.ibottom
        end
      end

      # D O:
      # if parent.lpos
      #   parent.lpos._scroll_bottom = Math.max(parent.lpos._scroll_bottom, yl)
      # end
      # p xi, xl, yi, xl

      v = LPos.new \
        xi: xi,
        xl: xl,
        yi: yi,
        yl: yl,
        base: base,
        no_left: no_left,
        no_right: no_right,
        no_top: no_top,
        no_bottom: no_bottom,
        renders: screen.renders
      v
    end

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

    # Returns parent `Widget` (if any) or `Screen` to which the widget may be attached.
    # If the widget already is `Screen`, returns `nil`.
    def parent_or_screen
      return self if Screen === self
      (@parent || screen).not_nil!
    end

    # Sends widget to front
    def front!
      set_index -1
    end

    # Sends widget to back
    def back!
      set_index 0
    end

    def set_index(index)
      return unless parent = @parent
      if index < 0
        index = parent.children.size + index
      end

      index = Math.max index, 0
      index = Math.min index, parent.children.size - 1

      i = parent.children.index self
      return unless i

      parent.children.insert index, parent.children.delete_at i
      nil
    end

    def _recalculate_index
      return 0 if !@screen || !@scrollable

      # D O
      # XXX
      # max = get_scroll_height - (aheight - iheight)

      max = @_clines.size - (aheight - iheight)
      max = 0 if max < 0
      emax = @_scroll_bottom - (aheight - iheight)
      emax = 0 if emax < 0

      @child_base = Math.min @child_base, Math.max emax, max

      if @child_base < 0
        @child_base = 0
      elsif @child_base > @base_limit
        @child_base = @base_limit
      end
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
