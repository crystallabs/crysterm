module Crysterm
  class Widget
    # Methods related to 2D position (X and Y).
    # Position in 3D (index) is in widget_index.cr

    # What action to take when widget is overflowing parent's rectangle?
    property overflow = Overflow::Ignore

    #
    # Left/top/right/bottom getters and setters. These values are exactly what the user has set, rather than being computed.
    # (I.e. they are equivalent of `widget.position` in blessed.)
    #

    # User-defined left
    getter left : Int32 | String | Nil

    # User-defined top
    getter top : Int32 | String | Nil

    # User-defined right
    getter right : Int32 | Nil

    # User-defined bottom
    getter bottom : Int32 | Nil

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

    #
    # Computed relative position on screen
    #

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

    #
    # Computed absolute position on screen
    #

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
  end
end
