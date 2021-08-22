module Crysterm
  class Widget < ::Crysterm::Object
    # Widget's parent `Widget`, if any.
    property parent : Widget?
    # This must be defined here rather than in src/mixin/children.cr because classes
    # which have children do not necessarily also have a parent (e.g. `Screen`).

    # Screen owning this element, forced to non-nil.
    # Each element must belong to a Screen if it is to be rendered/displayed anywhere.
    # If you just want to test for `Screen`, use `#screen?`.
    property! screen : ::Crysterm::Screen?

    # Screen owning this element, if any.
    # Each element must belong to a Screen if it is to be rendered/displayed anywhere.
    getter? screen : ::Crysterm::Screen?

    # User-defined left
    property left : Int32 | String | Nil

    # User-defined top
    property top : Int32 | String | Nil

    # User-defined right
    property right : Int32 | Nil

    # User-defined bottom
    property bottom : Int32 | Nil

    # User-defined width
    property width : Int32 | String | Nil

    # User-defined height
    property height : Int32 | String | Nil

    # Can Crysterm resize the widget if/when needed?
    property? resizable = false

    private property? fixed = false

    # Returns computed absolute left position
    def aleft
      _get_left false
    end

    # Returns computed absolute top position
    def atop
      _get_top false
    end

    # Returns computed absolute right position
    def aright
      _get_right false
    end

    # Returns computed absolute bottom position
    def abottom
      _get_bottom false
    end

    # Returns computed width
    def awidth
      _get_width false
    end

    # Returns computed height
    def aheight
      _get_height false
    end

    # Returns computed relative left position
    def rleft
      (aleft || 0) - ((parent_or_screen).not_nil!.aleft || 0)
    end

    # Returns computed relative top position
    def rtop
      (atop || 0) - ((parent_or_screen).not_nil!.atop || 0)
    end

    # Returns computed relative right position
    def rright
      (aright || 0) - ((parent_or_screen).not_nil!.aright || 0)
    end

    # Returns computed relative bottom position
    def rbottom
      (abottom || 0) - ((parent_or_screen).not_nil!.abottom || 0)
    end

    # Returns computed content offset from relative left position
    def ileft
      (@border ? 1 : 0) + @padding.left
      # return (@border && @border.left ? 1 : 0) + @padding.left
    end

    # Returns computed content offset from relative top position
    def itop
      (@border ? 1 : 0) + @padding.top
      # return (@border && @border.top ? 1 : 0) + @padding.top
    end

    # Returns computed content offset from relative right position
    def iright
      (@border ? 1 : 0) + @padding.right
      # return (@border && @border.right ? 1 : 0) + @padding.right
    end

    # Returns computed content offset from relative bottom position
    def ibottom
      (@border ? 1 : 0) + @padding.bottom
      # return (@border && @border.bottom ? 1 : 0) + @padding.bottom
    end

    # Returns computed inner width
    def iwidth
      # return (@border
      #   ? ((@border.left ? 1 : 0) + (@border.right ? 1 : 0)) : 0)
      #   + @padding.left + @padding.right
      (@border ? 2 : 0) + @padding.left + @padding.right
    end

    # Returns computed inner height
    def iheight
      # return (@border
      #   ? ((@border.top ? 1 : 0) + (@border.bottom ? 1 : 0)) : 0)
      #   + @padding.top + @padding.bottom
      (@border ? 2 : 0) + @padding.top + @padding.bottom
    end

    def _get_width(get)
      parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
      unless parent
        raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
      end
      width = @width
      case width
      when String
        if width == "half"
          width = "50%"
        end
        expr = width.split /(?=\+|-)/
        width = expr[0]
        width = width[0...-1].to_f / 100
        width = ((parent.awidth || 0) * width).to_i
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
        left = @left || 0
        if left.is_a? String
          if (left == "center")
            left = "50%"
          end
          expr = left.split(/(?=\+|-)/)
          left = expr[0]
          left = left[0...-1].to_f / 100
          left = ((parent.awidth || 0) * left).to_i
          left += expr[1].to_i if expr[1]?
        end
        width = (parent.awidth || 0) - (@right || 0) - left

        @parent.try do |pparent|
          if @auto_padding
            if ((!@left.nil? || @right.nil?) && @left != "center")
              width -= pparent.ileft
            end
            width -= pparent.iright
          end
        end
      end

      width
    end

    def _get_height(get)
      parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
      unless parent
        raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
      end
      height = @height
      case height
      when String
        if height == "half"
          height = "50%"
        end
        expr = height.split /(?=\+|-)/
        height = expr[0]
        height = height[0...-1].to_f / 100
        height = ((parent.aheight || 0) * height).to_i
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
        top = @top || 0
        if top.is_a? String
          if (top == "center")
            top = "50%"
          end
          expr = top.split(/(?=\+|-)/)
          top = expr[0]
          top = top[0...-1].to_f / 100
          top = ((parent.aheight || 0) * top).to_i
          top += expr[1].to_i if expr[1]?
        end
        height = (parent.aheight || 0) - (@bottom || 0) - top

        @parent.try do |pparent|
          if @auto_padding
            if ((!@top.nil? || @bottom.nil?) && @top != "center")
              height -= pparent.itop
            end
            height -= pparent.ibottom
          end
        end
      end

      height
    end

    def _get_left(get)
      parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
      unless parent
        raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
      end

      left = @left || 0
      if left.is_a? String
        if left == "center"
          left = "50%"
        end
        expr = left.split /(?=\+|-)/
        left = expr[0]
        left = left[0...-1].to_f / 100
        left = ((parent.awidth || 0) * left).to_i
        left += expr[1].to_i if expr[1]?
        if @left == "center"
          left -= (_get_width(get)) // 2
        end
      end

      if @left.nil? && !@right.nil?
        return screen.awidth - _get_width(get) - _get_right(get)
      end

      @parent.try do |pparent|
        if @auto_padding
          if ((!@left.nil? || @right.nil?) && @left != "center")
            left += pparent.ileft
          end
        end
      end

      (parent.aleft || 0) + left
    end

    def _get_right(get)
      parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
      unless parent
        raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
      end

      if @right.nil? && !@left.nil?
        right = screen.awidth - (_get_left(get) + _get_width(get))
        @parent.try do |pparent|
          if @auto_padding
            right += pparent.iright
          end
        end
      end

      right = (parent.aright || 0) + (@right || 0)
      @parent.try do |pparent|
        if @auto_padding
          right += pparent.iright
        end
      end

      right
    end

    def _get_top(get)
      parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
      unless parent
        raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
      end
      top = @top || 0
      if top.is_a? String
        if top == "center"
          top = "50%"
        end
        expr = top.split /(?=\+|-)/
        top = expr[0]
        top = top[0...-1].to_f / 100
        top = ((parent.aheight || 0) * top).to_i
        top += expr[1].to_i if expr[1]?
        if @top == "center"
          top -= _get_height(get) // 2
        end
      end

      if @top.nil? && !@bottom.nil?
        return screen.aheight - _get_height(get) - _get_bottom(get)
      end

      @parent.try do |pparent|
        if @auto_padding
          if ((!@top.nil? || @bottom.nil?) && @top != "center")
            top += pparent.itop
          end
        end
      end

      (parent.atop || 0) + top
    end

    def _get_bottom(get)
      parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
      unless parent
        raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
      end

      if @bottom.nil? && !@top.nil?
        bottom = screen.aheight - (_get_top(get) + _get_height(get))
        @parent.try do |pparent|
          if @auto_padding
            bottom += pparent.ibottom
          end
        end
        return bottom
      end

      bottom = (parent.abottom || 0) + (@bottom || 0)

      @parent.try do |pparent|
        if @auto_padding
          bottom += pparent.ibottom
        end
      end

      bottom
    end

    def width=(val : Int)
      return if @width == val
      clear_pos
      @width = val
      emit ::Crysterm::Event::Resize
      val
    end

    def height=(val : Int)
      return if height == val
      clear_pos
      @height = val
      emit ::Crysterm::Event::Resize
      val
    end

    def aleft=(val : Int)
      if (val.is_a? String)
        if (val == "center")
          val = screen.awidth // 2
          val -= @width // 2
        else
          expr = val.split(/(?=\+|-)/)
          val = expr[0]
          val = val.slice[0...-1].to_f / 100
          val = (screen.awidth * val).to_i
          val += expr[1] if expr[1]?
        end
      end
      val -= (parent_or_screen).not_nil!.aleft
      if (@left == val)
        return
      end
      clear_pos
      @left = val
      emit ::Crysterm::Event::Move
      val
    end

    def aright=(val : Int)
      val -= (parent_or_screen).not_nil!.aright
      return if (@right == val)
      clear_pos
      @right = val
      emit ::Crysterm::Event::Move
      val
    end

    def atop=(val : Int)
      if (val.is_a? String)
        if (val == "center")
          val = screen.aheight // 2
          val -= height // 2
        else
          expr = val.split(/(?=\+|-)/)
          val = expr[0].to_i
          val = val[0...-1].to_f / 100
          val = (screen.aheight * val).to_i
          val += expr[1] if expr[1]?
        end
      end
      val -= (parent_or_screen).not_nil!.atop
      return if (@top == val)
      clear_pos
      @top = val
      emit ::Crysterm::Event::Move
      val
    end

    def abottom=(val : Int)
      val -= (parent_or_screen).not_nil!.abottom
      return if (@bottom == val)
      clear_pos
      @bottom = val
      emit ::Crysterm::Event::Move
      val
    end

    def rleft=(val : Int)
      return if (@left == val)
      clear_pos
      @left = val
      emit ::Crysterm::Event::Move
      val
    end

    def rright=(val : Int)
      return if (@right == val)
      clear_pos
      @right = val
      emit ::Crysterm::Event::Move
      val
    end

    def rtop=(val : Int)
      return if (@top == val)
      clear_pos
      @top = val
      emit ::Crysterm::Event::Move
      val
    end

    def rbottom=(val : Int)
      return if (@bottom == val)
      clear_pos
      @bottom = val
      emit ::Crysterm::Event::Move
      val
    end

    # Clears area/position of widget's last render
    def clear_pos(get = false, override = false)
      return unless @screen
      lpos = _get_coords(get)
      return unless lpos
      screen.clear_region(lpos.xi, lpos.xl, lpos.yi, lpos.yl, override)
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
      base = @child_base
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
      # Note: Lists have a property where only
      # the list items are obfuscated.

      # Old way of doing things, this would not render right if a shrunken element
      # with lots of boxes in it was within a scrollable element.
      # See: $ c test/widget-shrink-fail.cr
      # thisparent = @parent

      thisparent = el

      # Using thisparent && el here to restrict both to non-nil
      if (thisparent && el && !noscroll && thisparent.is_a? Widget)
        ppos = thisparent.lpos

        # The resizable option can cause a stack overflow
        # by calling _get_coords on the child again.
        # if (!get && !thisparent.resizable?)
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
        # if (@left < 0 || @right < 0 || @top < 0 || @bottom < 0)
        if label?
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
            if @border
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
            if @border
              v -= 1
            end
            if thisparent.border
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
          if @border
            xi -= 1
          end
          if (thisparent.border)
            xi += 1
          end
        end
        if (xl > el_lpos.xl)
          xl = el_lpos.xl
          noright = true
          if @border
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

      parent = (parent_or_screen).not_nil!

      if ((parent.overflow == Overflow::ShrinkWidget) && (plp = parent.lpos))
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

    def _get_pos
      pos = @lpos
      pos.try do |pos2|
        # If it already has a pos2, just return.
        return pos2 if !pos2.responds_to? :aleft

        pos2.aleft = pos2.xi
        pos2.atop = pos2.yi
        pos2.aright = screen.awidth - pos2.xl
        pos2.abottom = screen.aheight - pos2.yl
        pos2.awidth = pos2.xl - pos2.xi
        pos2.aheight = pos2.yl - pos2.yi
      end

      pos
    end

    # end

    def reposition(event = nil)
      @_label.try do |_label|
        _label.rtop = @child_base - itop
        unless @auto_padding
          _label.rtop = @child_base
        end
        screen.render
      end
    end

    # Removes node from its parent.
    # This is identical to calling `#remove` on the parent object.
    def remove_parent
      @parent.try { |p| p.remove self }
    end

    # Inserts `element` to list of children at a specified position (at end by default)
    def insert(element, i = -1)
      if element.screen != screen
        element.screen.try &.detach(element)
      end

      element.remove_parent

      super
      screen.try &.attach(element)

      element.parent = self

      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element
    end

    def remove(element)
      return if element.parent != self

      return unless super
      element.parent = nil

      # TODO Enable
      # if i = screen.clickable.index(element)
      #  screen.clickable.delete_at i
      # end
      # if i = screen.keyable.index(element)
      #  screen.keyable.delete_at i
      # end

      element.emit(Crysterm::Event::Reparent, nil)
      emit(Crysterm::Event::Remove, element)
      # s= screen
      # raise Exception.new() unless s
      # screen_clickable= s.clickable
      # screen_keyable= s.keyable

      screen.try do |s|
        s.detach element

        if s.focused == element
          s.rewind_focus
        end
      end
    end

    def determine_screen
      scr = if Screen.total <= 1
              # This will use the first screen or create one if none created yet.
              # (Auto-creation helps writing scripts with less code.)
              Screen.global true
            elsif s = @parent
              while s && !(s.is_a? Screen)
                s = s.parent_or_screen
              end
              if s.is_a? Screen
                s
                # else
                #  raise Exception.new("No active screen found in parent chain.")
              end
              # elsif Screen.total > 0
              #  #Screen.instances[-1]
              #  Screen.instances[0]
              #  # XXX For the moment we use the first screen instead of the last one,
              #    as global, so same here - we just return the first one:
            end

      unless scr
        scr = Screen.global
      end

      unless scr
        raise Exception.new("No Screen found anywhere. Create one with Screen.new")
      end

      scr
    end

    # Returns parent `Widget` (if any) or `Screen` to which the widget may be attached.
    # If the widget already is `Screen`, returns `nil`.
    def parent_or_screen
      return nil if Screen === self
      @parent || screen
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
        if (el.left.nil? && !el.right.nil?)
          ret.xl = xi + (ret.xl - ret.xi)
          ret.xi = xi
          if @auto_padding
            # Maybe just do this no matter what.
            ret.xl += ileft
            ret.xi += ileft
          end
        end
        if (el.top.nil? && !el.bottom.nil?)
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

      if (@width.nil? && (@left.nil? || @right.nil?))
        if (@left.nil? && !@right.nil?)
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
      if (@height.nil? && (@top.nil? || @bottom.nil?) && (!@scrollable || @_is_list))
        # Note: Lists get special treatment if they are shrunken - assume they
        # want all list items showing. This is one case we can calculate the
        # height based on items/boxes.
        if @_is_list
          myi = 0 - itop
          myl = @items.size + ibottom
        end
        if (@top.nil? && !@bottom.nil?)
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
    def _minimal_content_rectangle(xi, xl, yi, yl)
      h = @_clines.size
      w = @_clines.max_width || 0

      # The extra IFs which are commented appear unnecessary.
      # If a person sets resizable: true, this is expected to happen
      # no matter what; not only if other coordinates are also left empty.

      if (@width.nil? && (@left.nil? || @right.nil?))
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
