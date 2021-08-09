require "./event"
require "./helpers"

module Crysterm
  class Widget < ::Crysterm::Object

    # Used to represent minimal widget dimensions, after running a method
    # to determine them.
    #
    # Used only internally; could be replaced by anything else that has
    # the necessary properties.
    class ShrinkBox
      property xi : Int32
      property xl : Int32
      property yi : Int32
      property yl : Int32
      property get : Bool

      def initialize(@xi, @xl, @yi, @yl, @get = false)
      end
    end

    # :nodoc:
    class Box < Widget
    end

    # :nodoc:
    class ListTable < Widget
    end

    # :nodoc:
    class Input < Box
    end

    # :nodoc:
    class TextArea < Input
    end

    module Pos
      # Number of times object was rendered
      property renders = 0

      # Absolute left offset.
      property aleft : Int32? = nil

      # Absolute top offset.
      property atop : Int32? = nil

      # Absolute right offset.
      property aright : Int32? = nil

      # Absolute bottom offset.
      property abottom : Int32? = nil

      # Relative coordinates as default properties

      # Returns relative left position
      def left
        @rleft
      end

      # Returns relative right position
      def right
        @rright
      end

      # Returns relative top position
      def top
        @rtop
      end

      # Returns relative bottom position
      def bottom
        @rbottom
      end

      # Sets relative left position
      def left=(arg)
        @rleft = arg
      end

      # Sets relative right position
      def right=(arg)
        @rright = arg
      end

      # Sets relative top position
      def top=(arg)
        @rtop = arg
      end

      # Sets relative bottom position
      def bottom=(arg)
        @rbottom = arg
      end

      # Absolute position on screen
      property position = Tput::Position.new

      property? scrollable = false

      # Last rendered position
      property lpos : LPos? = nil

      # Helper class implementing only minimal position-related interface.
      # Used for holding widget's last rendered position.
      class LPos
        # Starting cell on X axis
        property xi : Int32 = 0

        # Ending cell on X axis
        property xl : Int32 = 0

        # Starting cell on Y axis
        property yi : Int32 = 0

        # Endint cell on Y axis
        property yl : Int32 = 0

        property base : Int32 = 0
        property noleft : Bool = false
        property noright : Bool = false
        property notop : Bool = false
        property nobot : Bool = false

        # Number of times object was rendered
        property renders = 0

        property aleft : Int32? = nil
        property atop : Int32? = nil
        property aright : Int32? = nil
        property abottom : Int32? = nil
        property width : Int32? = nil
        property height : Int32? = nil

        # property ileft : Int32 = 0
        # property itop : Int32 = 0
        # property iright : Int32 = 0
        # property ibottom : Int32 = 0

        property _scroll_bottom : Int32 = 0
        property _clean_sides : Bool = false

        def initialize(
          @xi = 0,
          @xl = 0,
          @yi = 0,
          @yl = 0,
          @base = 0,
          @noleft = false,
          @noright = false,
          @notop = false,
          @nobot = false,
          @renders = 0,

          # Disable all this:
          @aleft = nil,
          @atop = nil,
          @aright = nil,
          @abottom = nil,
          @width = nil,
          @height = nil
        )
        end
      end
    end

    module Position
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
        if @resizable
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
          # if (@position.left < 0 || @position.right < 0 || @position.top < 0 || @position.bottom < 0)
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

      # Positioning

      def _get_width(get)
        parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
        unless parent
          raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
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

          @parent.try do |pparent|
            if @auto_padding
              if ((!@position.left.nil? || @position.right.nil?) && @position.left != "center")
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

          @parent.try do |pparent|
            if @auto_padding
              if ((!@position.top.nil? || @position.bottom.nil?) && @position.top != "center")
                height -= pparent.itop
              end
              height -= pparent.ibottom
            end
          end
        end

        height
      end

      def height
        _get_height false
      end

      def _get_left(get)
        parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
        unless parent
          raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
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
          return screen.width - _get_width(get) - _get_right(get)
        end

        @parent.try do |pparent|
          if @auto_padding
            if ((!@position.left.nil? || @position.right.nil?) && @position.left != "center")
              left += pparent.ileft
            end
          end
        end

        (parent.aleft || 0) + left
      end

      def aleft
        _get_left false
      end

      def _get_right(get)
        parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
        unless parent
          raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
        end

        if @position.right.nil? && !@position.left.nil?
          right = screen.width - (_get_left(get) + _get_width(get))
          @parent.try do |pparent|
            if @auto_padding
              right += pparent.iright
            end
          end
        end

        right = (parent.aright || 0) + (@position.right || 0)
        @parent.try do |pparent|
          if @auto_padding
            right += pparent.iright
          end
        end

        right
      end

      def aright
        _get_right false
      end

      def _get_top(get)
        parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
        unless parent
          raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
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
          return screen.height - _get_height(get) - _get_bottom(get)
        end

        @parent.try do |pparent|
          if @auto_padding
            if ((!@position.top.nil? || @position.bottom.nil?) && @position.top != "center")
              top += pparent.itop
            end
          end
        end

        (parent.atop || 0) + top
      end

      def atop
        _get_top false
      end

      def _get_bottom(get)
        parent = get ? (parent_or_screen).try(&._get_pos) : (parent_or_screen)
        unless parent
          raise "Widget's #parent and #screen not found. Did you create a Widget without assigning it to a parent and screen?"
        end

        if @position.bottom.nil? && !@position.top.nil?
          bottom = screen.height - (_get_top(get) + _get_height(get))
          @parent.try do |pparent|
            if @auto_padding
              bottom += pparent.ibottom
            end
          end
          return bottom
        end

        bottom = (parent.abottom || 0) + (@position.bottom || 0)

        @parent.try do |pparent|
          if @auto_padding
            bottom += pparent.ibottom
          end
        end

        bottom
      end

      def abottom
        _get_bottom false
      end

      def rleft
        (aleft || 0) - ((parent_or_screen).not_nil!.aleft || 0)
      end

      def rright
        (aright || 0) - ((parent_or_screen).not_nil!.aright || 0)
      end

      def rtop
        (atop || 0) - ((parent_or_screen).not_nil!.atop || 0)
      end

      def rbottom
        (abottom || 0) - ((parent_or_screen).not_nil!.abottom || 0)
      end

      def width=(val : Int)
        return if @width == val
        clear_pos
        @position.width = val
        emit ::Crysterm::Event::Resize
        val
      end

      def height=(val : Int)
        return if height == val
        clear_pos
        @position.height = val
        emit ::Crysterm::Event::Resize
        val
      end

      def aleft=(val : Int)
        if (val.is_a? String)
          if (val == "center")
            val = screen.width // 2
            val -= @width // 2
          else
            expr = val.split(/(?=\+|-)/)
            val = expr[0]
            val = val.slice[0...-1].to_f / 100
            val = (screen.width * val).to_i
            val += expr[1] if expr[1]?
          end
        end
        val -= (parent_or_screen).not_nil!.aleft
        if (@position.left == val)
          return
        end
        clear_pos
        @position.left = val
        emit ::Crysterm::Event::Move
        val
      end

      def aright=(val : Int)
        val -= (parent_or_screen).not_nil!.aright
        return if (@position.right == val)
        clear_pos
        @position.right = val
        emit ::Crysterm::Event::Move
        val
      end

      def atop=(val : Int)
        if (val.is_a? String)
          if (val == "center")
            val = screen.height // 2
            val -= height // 2
          else
            expr = val.split(/(?=\+|-)/)
            val = expr[0].to_i
            val = val[0...-1].to_f / 100
            val = (screen.height * val).to_i
            val += expr[1] if expr[1]?
          end
        end
        val -= (parent_or_screen).not_nil!.atop
        return if (@position.top == val)
        clear_pos
        @position.top = val
        emit ::Crysterm::Event::Move
        val
      end

      def abottom=(val : Int)
        val -= (parent_or_screen).not_nil!.abottom
        return if (@position.bottom == val)
        clear_pos
        @position.bottom = val
        emit ::Crysterm::Event::Move
        val
      end

      def rleft=(val : Int)
        return if (@position.left == val)
        clear_pos
        @position.left = val
        emit ::Crysterm::Event::Move
        val
      end

      def rright=(val : Int)
        return if (@position.right == val)
        clear_pos
        @position.right = val
        emit ::Crysterm::Event::Move
        val
      end

      def rtop=(val : Int)
        return if (@position.top == val)
        clear_pos
        @position.top = val
        emit ::Crysterm::Event::Move
        val
      end

      def rbottom=(val : Int)
        return if (@position.bottom == val)
        clear_pos
        @position.bottom = val
        emit ::Crysterm::Event::Move
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

      # Rendition and rendering

      # Returns minimum widget size based on bounding box
      def _get_shrink_box(xi, xl, yi, yl, get)
        if @children.empty?
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

        ShrinkBox.new xi: xi, xl: xl, yi: yi, yl: yl
      end

      # Returns minimum widget size based on content
      def _get_shrink_content(xi, xl, yi, yl)
        h = @_clines.size
        w = @_clines.mwidth || 1

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

        ShrinkBox.new xi: xi, xl: xl, yi: yi, yl: yl
      end

      # Returns minimum widget size
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

        ShrinkBox.new xi: xi, xl: xl, yi: yi, yl: yl
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
        pos.try do |pos2|
          # If it already has a pos2, just return.
          return pos2 if !pos2.responds_to? :aleft

          pos2.aleft = pos2.xi
          pos2.atop = pos2.yi
          pos2.aright = screen.columns - pos2.xl
          pos2.abottom = screen.rows - pos2.yl
          pos2.width = pos2.xl - pos2.xi
          pos2.height = pos2.yl - pos2.yi
        end

        pos
      end
    end

    module Content
      include Helpers

      class CLines < Array(String)
        property string = ""
        property mwidth = 0
        property width = 0

        property content : String = ""

        property real = [] of String

        property fake = [] of String

        property ftor = [] of Array(Int32)
        property rtof = [] of Int32
        property ci = [] of Int32

        property attr : Array(Int32)? = [] of Int32

        property ci = [] of Int32
      end

      property _clines = CLines.new

      # Widget's text content. Includes any attributes and tags.
      getter content : String = ""

      # Printable, word-wrapped content, ready for rendering into the element.
      property _pcontent : String?

      def set_content(content = "", no_clear = false, no_tags = false)
        clear_pos unless no_clear

        # XXX make it possible to have `update_context`, which only updates
        # internal structures, not @content (for rendering purposes, where
        # original content should not be modified).
        @content = content

        parse_content(no_tags)
        emit(Crysterm::Event::SetContent)
      end

      def get_content
        return "" if @_clines.empty?
        @_clines.fake.join "\n"
      end

      def set_text(content = "", no_clear = false)
        content = content.gsub /\x1b\[[\d;]*m/, ""
        set_content content, no_clear, true
      end

      def get_text
        get_content.gsub /\x1b\[[\d;]*m/, ""
      end

      def parse_content(no_tags = false)
        return false unless @screen # XXX why?

        Log.trace { "Parsing widget content: #{@content.inspect}" }

        colwidth = width - iwidth
        if (@_clines.nil? || @_clines.empty? || @_clines.width != colwidth || @_clines.content != @content)
          content =
            @content.gsub(/[\x00-\x08\x0b-\x0c\x0e-\x1a\x1c-\x1f\x7f]/, "")
              .gsub(/\x1b(?!\[[\d;]*m)/, "")
              .gsub(/\r\n|\r/, "\n")
              .gsub(/\t/, @tabc)

          Log.trace { "Internal content is #{content.inspect}" }

          if true # (screen.full_unicode)
            # double-width chars will eat the next char after render. create a
            # blank character after it so it doesn't eat the real next char.
            # TODO
            # content = content.replace(unicode.chars.all, '$1\x03')

            # iTerm2 cannot render combining characters properly.
            if screen.display.tput.emulator.iterm2?
              # TODO
              # content = content.replace(unicode.chars.combining, "")
            end
          else
            # no double-width: replace them with question-marks.
            # TODO
            # content = content.gsub unicode.chars.all, "??"
            # delete combining characters since they're 0-width anyway.
            # Note: We could drop this, the non-surrogates would get changed to ? by
            # the unicode filter, and surrogates changed to ? by the surrogate
            # regex. however, the user might expect them to be 0-width.
            # Note: Might be better for performance to drop it!
            # TODO
            # content = content.replace(unicode.chars.combining, '')
            # no surrogate pairs: replace them with question-marks.
            # TODO
            # content = content.replace(unicode.chars.surrogate, '?')
            # XXX Deduplicate code here:
            # content = helpers.dropUnicode(content)
          end

          if !no_tags
            content = _parse_tags content
          end
          Log.trace { "After _parse_tags: #{content.inspect}" }

          @_clines = _wrap_content(content, colwidth)
          @_clines.width = colwidth
          @_clines.content = @content
          @_clines.attr = _parse_attr @_clines
          @_clines.ci = [] of Int32
          @_clines.reduce(0) do |total, line|
            @_clines.ci.push(total)
            total + line.size + 1
          end

          @_pcontent = @_clines.join "\n"
          emit Crysterm::Event::ParsedContent

          return true
        end

        # Need to calculate this every time because the default fg/bg may change.
        @_clines.attr = _parse_attr(@_clines) || @_clines.attr

        false
      end

      # Convert `{red-fg}foo{/red-fg}` to `\x1b[31mfoo\x1b[39m`.
      def _parse_tags(text)
        if (!@parse_tags)
          return text
        end
        unless (text =~ /{\/?[\w\-,;!#]*}/)
          return text
        end

        outbuf = ""
        # state

        bg = [] of String
        fg = [] of String
        flag = [] of String

        cap = nil
        # slash
        # param
        # attr
        esc = nil

        loop do
          if (!esc && (cap = text.match /^{escape}/))
            text = text[cap[0].size..]
            esc = true
            next
          end

          if (esc && (cap = text.match /^([\s\S]+?){\/escape}/))
            text = text[cap[0].size..]
            outbuf += cap[1]
            esc = false
            next
          end

          if (esc)
            # raise "Unterminated escape tag."
            outbuf += text
            break
          end

          # Matches {normal}{/normal} and all other tags
          if (cap = text.match /^{(\/?)([\w\-,;!#]*)}/)
            text = text[cap[0].size..]
            slash = (cap[1] == "/")
            # XXX Tags must be specified such as {light-blue-fg}, but are then
            # parsed here with - being ' '. See why? Can we work with - and skip
            # this replacement part?
            param = (cap[2].gsub(/-/, ' '))

            if (param == "open")
              outbuf += '{'
              next
            elsif (param == "close")
              outbuf += '}'
              next
            end

            if (param[-3..]? == " bg")
              state = bg
            elsif (param[-3..]? == " fg")
              state = fg
            else
              state = flag
            end

            if (slash)
              if (!param || param.blank?)
                outbuf += screen.display.tput._attr("normal") || ""
                bg.clear
                fg.clear
                flag.clear
              else
                attr = screen.display.tput._attr(param, false)
                if (attr.nil?)
                  outbuf += cap[0]
                else
                  # D O:
                  # if (param !== state[state.size - 1])
                  #   throw new Error('Misnested tags.')
                  # }
                  state.pop
                  if (state.size > 0)
                    outbuf += screen.display.tput._attr(state[-1]) || ""
                  else
                    outbuf += attr
                  end
                end
              end
            else
              if (!param)
                outbuf += cap[0]
              else
                attr = screen.display.tput._attr(param)
                if (attr.nil?)
                  outbuf += cap[0]
                else
                  state.push(param)
                  outbuf += attr
                end
              end
            end

            next
          end

          if (cap = text.match /^[\s\S]+?(?={\/?[\w\-,;!#]*})/)
            text = text[cap[0].size..]
            outbuf += cap[0]
            next
          end

          outbuf += text
          break
        end

        outbuf
      end

      def _parse_attr(lines)
        dattr = sattr(style)
        attr = dattr
        attrs = [] of Int32
        # line
        # i
        # j
        # c

        if (lines[0].attr == attr)
          return
        end

        (0...lines.size).each do |j|
          line = lines[j]
          attrs.push attr
          unless attrs.size == j + 1
            raise "indexing error"
          end
          (0...line.size).each do |i|
            if (line[i] == '\e')
              if (c = line[1..].match /^\x1b\[[\d;]*m/)
                attr = screen.attr_code(c[0], attr, dattr)
                # i += c[0].size - 1 # Unused
              end
            end
          end
          # j += 1 # Unused
        end

        attrs
      end

      # Wraps content based on available widget width
      def _wrap_content(content, colwidth)
        default_state = @align
        wrap = @wrap
        margin = 0
        rtof = [] of Int32
        ftor = [] of Array(Int32)
        # outbuf = [] of String
        outbuf = CLines.new
        # line
        # align
        # cap
        # total
        # i
        # part
        # j
        # lines
        # rest

        if !content || content.empty?
          outbuf.push(content)
          outbuf.rtof = [0]
          outbuf.ftor = [[0]]
          outbuf.fake = [] of String
          outbuf.real = outbuf
          outbuf.mwidth = 0
          return outbuf
        end

        lines = content.split "\n"

        if @scrollbar
          margin += 1
        end
        if is_a? Widget::TextArea
          margin += 1
        end
        if (colwidth > margin)
          colwidth -= margin
        end

        # What follows is a relatively large loop with subloops, all implemented with 'loop do'.
        # This is to simultaneously work around 2 issues in Crystal -- (1) not having loop labels,
        # and (2) while loop mistakenly not returning break's return value. Elegance is impacted.

        #      main:
        no = 0
        # NOTE Done with loop+break due to https://github.com/crystal-lang/crystal/issues/1277
        loop do
          break unless no < lines.size

          line = lines[no]
          align = default_state
          align_left_too = false

          ftor.push [] of Int32

          # Handle alignment tags.
          if @parse_tags
            if (cap = line.match /^{(left|center|right)}/)
              align_left_too = true
              line = line[cap[0].size..]
              align = default_state = case cap[1]
                                      when "center"
                                        Tput::AlignFlag::Center
                                      when "left"
                                        Tput::AlignFlag::Left
                                      else
                                        Tput::AlignFlag::Right
                                      end
            end
            if (cap = line.match /{\/(left|center|right)}$/)
              line = line[0...(line.size - cap[0].size)]
              # Reset default_state to whatever alignment the widget has by default.
              default_state = @align
            end
          end

          # If the string is apparently too long, wrap it.
          # NOTE Done with loop+break due to https://github.com/crystal-lang/crystal/issues/1277
          loop_ret = loop do
            break unless line.size > colwidth
            # Measure the real width of the string.
            total = 0
            i = 0
            # NOTE Done with loop+break due to https://github.com/crystal-lang/crystal/issues/1277
            loop do
              break unless i < line.size
              while (line[i] == '\e')
                while (line[i] && line[i] != 'm')
                  i += 1
                end
              end
              if (line[i]?.nil?)
                break
              end
              total += 1
              if (total == colwidth)
                # If we're not wrapping the text, we have to finish up the rest of
                # the control sequences before cutting off the line.
                i += 1
                if (!wrap)
                  rest = line[i..].scan(/\x1b\[[^m]*m/)
                  rest = rest.any? ? rest.join : ""
                  outbuf.push _align(line[0...i] + rest, colwidth, align, align_left_too)
                  ftor[no].push(outbuf.size - 1)
                  rtof.push(no)
                  break :main
                end
                # XXX TODO
                # if (!screen.fullUnicode)
                # Try to find a char to break on.
                if (i != line.size)
                  j = i
                  # TODO how can the condition and subsequent IF ever match
                  # with the line[j] thing?
                  while ((j > i - 10) && (j > 0) && (j -= 1) && (line[j] != ' '))
                    if (line[j] == ' ')
                      i = j + 1
                    end
                  end
                end
                # end
                break
              end
              i += 1
            end

            part = line[0...i]
            line = line[i..]

            outbuf.push _align(part, colwidth, align, align_left_too)
            ftor[no].push(outbuf.size - 1)
            rtof.push(no)

            # Make sure we didn't wrap the line to the very end, otherwise
            # we get a pointless empty line after a newline.
            if (line == "")
              break :main
            end

            # If only an escape code got cut off, at it to `part`.
            if (line.match /^(?:\x1b[\[\d;]*m)+$/)
              outbuf[outbuf.size - 1] += line
              break :main
            end
          end

          if loop_ret == :main
            no += 1
            next
          end

          outbuf.push(_align(line, colwidth, align, align_left_too))
          ftor[no].push(outbuf.size - 1)
          rtof.push(no)

          no += 1
        end

        outbuf.rtof = rtof
        outbuf.ftor = ftor
        outbuf.fake = lines
        outbuf.real = outbuf

        outbuf.mwidth = outbuf.reduce(0) do |current, line|
          line = line.gsub(/\x1b\[[\d;]*m/, "")
          # XXX Does reduce() need explicit addition to `current`?
          line.size > current ? line.size : current
        end

        outbuf
      end

      # Aligns content
      def _align(line, width, align = Tput::AlignFlag::None, align_left_too = false)
        return line if align.none?

        cline = line.gsub /\x1b\[[\d;]*m/, ""
        len = cline.size

        # XXX In blessed's code (and here) it was done only with this commented
        # line below. But after/around the May 28 2021 changes, this stopped
        # centering texts. Upon investigation, it was found this is because a
        # Layout sets all its children to #resizable=true (shrink=true in blessed),
        # so the free width (s) results being 0 here. But why this code worked
        # up to May is unexplained, since no obvious changes were done in this
        # code. Or, cn this be a bug we unintentionally fixed?
        # s = @resizable ? 0 : width - len
        s = (@resizable && !width) ? 0 : width - len

        return line if len == 0
        return line if s < 0

        if (align & Tput::AlignFlag::HCenter) != Tput::AlignFlag::None
          s = " " * (s//2)
          return s + line + s
        elsif align.right?
          s = " " * s
          return s + line
        elsif align_left_too && align.left?
          # Technically, left align is visually the same as no align at all.
          # But when text is aligned to center or right, all the available empty space is padded
          # with spaces (around the text in center align, and in front of text in right align).
          # So, because of this padding with spaces, which affects the size of the widget, we
          # want to pad {left} align for uniformity as well.
          #
          # But, because aligning left affects almost everything in undesired ways (a lot
          # more chars are present, and cursor in text widgets is wrong), we do not want to do
          # this when Widget's `align = AlignFlag::Left`. We only want to do it when there is
          # "{left}" in content, and parse_tags is true.
          #
          # This should ensure that {left|center|right} behave 100% identical re. the effect
          # it has on row width. To see the old behavior without this, comment this elseif,
          # run test/widget-list.cr, and observe the look of the first element in the list
          # vs. the other elements when they are selected.
          s = " " * s
          return line + s
        elsif @parse_tags && line.index /\{|\}/
          # XXX This is basically Tput::AlignFlag::Spread, but not sure
          # how to put that as a flag yet. Maybe this (or another)
          # widget flag could mean to spread words to fill up the whole
          # line, increasing spaces between them?
          parts = line.split /\{|\}/

          cparts = cline.split /\{|\}/
          if cparts[0]? && cparts[2]? # Don't trip on just single { or }
            s = Math.max(width - cparts[0].size - cparts[2].size, 0)
            s = " " * s
            return "#{parts[0]}#{s}#{parts[2]}"
          else
            # Nothing; will default to returning `line` below.
          end
        end

        line
      end

      def insert_line(i = nil, line = "")
        if (line.is_a? String)
          line = line.split("\n")
        end

        if (i.nil?)
          i = @_clines.ftor.size
        end

        i = Math.max(i, 0)

        while (@_clines.fake.size < i)
          @_clines.fake.push("")
          @_clines.ftor.push([@_clines.push("").size - 1])
          @_clines.rtof[@_clines.fake.size - 1]
        end

        # NOTE: Could possibly compare the first and last ftor line numbers to see
        # if they're the same, or if they fit in the visible region entirely.
        start = @_clines.size
        # diff
        # real

        if (i >= @_clines.ftor.size)
          real = @_clines.ftor[@_clines.ftor.size - 1]
          real = real[-1] + 1
        else
          real = @_clines.ftor[i][0]
        end

        line.size.times do |j|
          @_clines.fake.insert(i + j, line[j])
        end

        set_content(@_clines.fake.join("\n"), true)

        diff = @_clines.size - start

        if (diff > 0)
          pos = _get_coords
          if (!pos || pos == 0)
            return
          end

          height = pos.yl - pos.yi - iheight
          base = @child_base
          visible = real >= base && real - base < height

          if (pos && visible && screen.clean_sides(self))
            screen.insert_line(diff,
              pos.yi + itop + real - base,
              pos.yi,
              pos.yl - ibottom - 1)
          end
        end
      end

      def delete_line(i = nil, n = 1)
        if (i.nil?)
          i = @_clines.ftor.size - 1
        end

        i = Math.max(i, 0)
        i = Math.min(i, @_clines.ftor.size - 1)

        # NOTE: Could possibly compare the first and last ftor line numbers to see
        # if they're the same, or if they fit in the visible region entirely.
        start = @_clines.size
        # diff
        real = @_clines.ftor[i][0]

        while (n > 0)
          n -= 1
          @_clines.fake.delete_at i
        end

        set_content(@_clines.fake.join("\n"), true)

        diff = start - @_clines.size

        # XXX clear_pos() without diff statement?
        height = 0

        if (diff > 0)
          pos = _get_coords
          if (!pos || pos == 0)
            return
          end

          height = pos.yl - pos.yi - iheight

          base = @child_base
          visible = real >= base && real - base < height

          if (pos && visible && screen.clean_sides(self))
            screen.delete_line(diff,
              pos.yi + itop + real - base,
              pos.yi,
              pos.yl - ibottom - 1)
          end
        end

        if (@_clines.size < height)
          clear_pos()
        end
      end

      def insert_top(line)
        fake = @_clines.rtof[@child_base]
        insert_line(fake, line)
      end

      def insert_bottom(line)
        h = (@child_base) + height - iheight
        i = Math.min(h, @_clines.size)
        fake = @_clines.rtof[i - 1] + 1

        insert_line(fake, line)
      end

      def delete_top(n = 1)
        fake = @_clines.rtof[@child_base]
        delete_line(fake, n)
      end

      def delete_bottom(n)
        h = (@child_base) + height - 1 - iheight
        i = Math.min(h, @_clines.size - 1)
        fake = @_clines.rtof[i]

        n = 1 if !n || n == 0

        delete_line(fake - (n - 1), n)
      end

      def set_line(i, line)
        i = Math.max(i, 0)
        while (@_clines.fake.size < i)
          @_clines.fake.push("")
        end
        @_clines.fake[i] = line
        set_content(@_clines.fake.join("\n"), true)
      end

      def set_baseline(i, line)
        fake = @_clines.rtof[@child_base]
        set_line(fake + i, line)
      end

      def get_line(i)
        i = Math.max(i, 0)
        i = Math.min(i, @_clines.fake.size - 1)
        @_clines.fake[i]
      end

      def get_baseline(i)
        fake = @_clines.rtof[@child_base]
        get_line(fake + i)
      end

      def clear_line(i)
        i = Math.min(i, @_clines.fake.size - 1)
        set_line(i, "")
      end

      def clear_base_line(i)
        fake = @_clines.rtof[@child_base]
        clear_line(fake + i)
      end

      def unshift_line(line)
        insert_line(0, line)
      end

      def shift_line(n)
        delete_line(0, n)
      end

      def push_line(line)
        if (!@content)
          return set_line(0, line)
        end
        insert_line(@_clines.fake.size, line)
      end

      def pop_line(n)
        delete_line(@_clines.fake.size - 1, n)
      end

      def get_lines
        @_clines.fake.dup
      end

      def get_screen_lines
        @_clines.dup
      end

      def str_width(text)
        text = @parse_tags ? strip_tags(text) : text
        # return screen.full_unicode ? unicode.str_width(text) : helpers.drop_unicode(text).size
        # text = text
        text.size # or bytesize?
      end
    end

    class StringIndex
      def initialize(@object : String) : String?
      end

      def [](i : Int)
        i < 0 ? nil : @object[i]
      end

      def []?(i : Int)
        i < 0 ? nil : @object[i]?
      end

      def [](range : Range)
        @object[range]
      end

      # def []?(range : Range)
      # @object[range]
      # end

      def size
        @object.size
      end
    end

    module Rendering
      include Crystallabs::Helpers::Alias_Methods

      property items = [] of Widget::Box

      # Here be dragons

      # Renders all child elements into the output buffer.
      def _render(with_children = true)
        emit Crysterm::Event::PreRender

        # XXX TODO Is this a hack in Crysterm? It allows elements within lists to be styled as appropriate.
        style = self.style
        parent.try do |parent2|
          if parent2._is_list && parent2.is_a? Widget::List
            if parent2.items[parent2.selected]? == self
              style = parent2.style.selected
            else
              style = parent2.style.item
            end
          end
        end

        parse_content

        coords = _get_coords(true)
        unless coords
          @lpos = nil
          return
        end

        if (coords.xl - coords.xi <= 0)
          coords.xl = Math.max(coords.xl, coords.xi)
          return
        end

        if (coords.yl - coords.yi <= 0)
          coords.yl = Math.max(coords.yl, coords.yi)
          return
        end

        lines = screen.lines
        xi = coords.xi
        xl = coords.xl
        yi = coords.yi
        yl = coords.yl
        # x
        # y
        # cell
        # attr
        # ch
        # Log.trace { lines.inspect }
        content = StringIndex.new @_pcontent || ""
        ci = @_clines.ci[coords.base]? || 0 # XXX Is it ok that array lookup can be nil? and defaulting to 0?
        # battr
        # dattr
        # c
        # visible
        # i
        bch = style.char

        # D O:
        # Clip content if it's off the edge of the screen
        # if (xi + ileft < 0 || yi + itop < 0)
        #   clines = @_clines.slice()
        #   if (xi + ileft < 0)
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
        #         if (++t == -(xi + ileft) + 1) break
        #       end
        #       clines[i] = csis + clines[i].substring(j)
        #     end
        #   end
        #   if (yi + itop < 0)
        #     clines = clines.slice(-(yi + itop))
        #   end
        #   content = clines.join('\n')
        # end

        if (coords.base >= @_clines.ci.size)
          # Can be @_pcontent, but this is the same here, plus not_nil!
          ci = content.size
        end

        @lpos = coords

        @border.try do |border|
          if border.type.line?
            screen._border_stops[coords.yi] = true
            screen._border_stops[coords.yl - 1] = true
            # D O:
            # if (!screen._border_stops[coords.yi])
            #   screen._border_stops[coords.yi] = { xi: coords.xi, xl: coords.xl }
            # else
            #   if (screen._border_stops[coords.yi].xi > coords.xi)
            #     screen._border_stops[coords.yi].xi = coords.xi
            #   end
            #   if (screen._border_stops[coords.yi].xl < coords.xl)
            #     screen._border_stops[coords.yi].xl = coords.xl
            #   end
            # end
            # screen._border_stops[coords.yl - 1] = screen._border_stops[coords.yi]
          end
        end

        dattr = sattr style
        attr = dattr

        # If we're in a scrollable text box, check to
        # see which attributes this line starts with.
        if (ci > 0)
          attr = @_clines.attr.try(&.[Math.min(coords.base, @_clines.size - 1)]?) || 0
        end

        if @border
          xi += 1
          xl -= 1
          yi += 1
          yl -= 1
        end

        # If we have padding/valign, that means the
        # content-drawing loop will skip a few cells/lines.
        # To deal with this, we can just fill the whole thing
        # ahead of time. This could be optimized.
        if (@padding.any? || (!@align.top?))
          if transparency = style.transparency
            (Math.max(yi, 0)...yl).each do |y|
              if !lines[y]?
                break
              end
              (Math.max(xi, 0)...xl).each do |x|
                if !lines[y][x]?
                  break
                end
                lines[y][x].attr = Colors.blend(attr, lines[y][x].attr, alpha: transparency)
                # D O:
                # lines[y][x].char = bch
                lines[y].dirty = true
              end
            end
          else
            screen.fill_region(dattr, bch, xi, xl, yi, yl)
          end
        end

        if @padding.any?
          xi += @padding.left
          xl -= @padding.right
          yi += @padding.top
          yl -= @padding.bottom
        end

        # Determine where to place the text if it's vertically aligned.
        if @align.v_center? || @align.bottom?
          visible = yl - yi
          if (@_clines.size < visible)
            if @align.v_center?
              visible = visible // 2
              visible -= @_clines.size // 2
            elsif @align.bottom?
              visible -= @_clines.size
            end
            ci -= visible * (xl - xi)
          end
        end

        # Draw the content and background.
        # yi.step to: yl-1 do |y|
        (yi...yl).each do |y|
          if (!lines[y]?)
            if (y >= screen.height || yl < ibottom)
              break
            else
              next
            end
          end
          # TODO - make cell exist only if there's something to be drawn there?
          x = xi - 1
          while x < xl - 1
            x += 1
            cell = lines[y][x]?
            unless cell
              if x >= screen.width || xl < iright
                break
              else
                next
              end
            end

            ch = content[ci]? || bch
            # Log.trace { ci }
            ci += 1

            # D O:
            # if (!content[ci] && !coords._content_end)
            #   coords._content_end = { x: x - xi, y: y - yi }
            # end

            # Handle escape codes.
            while (ch == '\e')
              cnt = content[(ci - 1)..]
              if (c = cnt.match /^\x1b\[[\d;]*m/)
                ci += c[0].size - 1
                attr = screen.attr_code(c[0], attr, dattr)
                # Ignore foreground changes for selected items.
                parent.try do |parent2|
                  if parent2._is_list && parent2.interactive? && parent2.is_a?(Widget::List) && parent2.items[parent2.selected] == self # XXX && parent2.invert_selected
                    attr = (attr & ~(0x1ff << 9)) | (dattr & (0x1ff << 9))
                  end
                end
                ch = content[ci]? || bch
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
                x -= 1
                next
              end
              # We could use fill_region here, name the
              # outer loop, and continue to it instead.
              ch = bch
              while (x < xl)
                cell = lines[y][x]?
                if (!cell)
                  break
                end
                if transparency = style.transparency
                  lines[y][x].attr = Colors.blend(attr, lines[y][x].attr, alpha: transparency)
                  if content[ci - 1]?
                    lines[y][x].char = ch
                  end
                  lines[y].dirty = true
                else
                  if cell != {attr, ch}
                    lines[y][x].attr = attr
                    lines[y][x].char = ch
                    lines[y].dirty = true
                  end
                end
                x += 1
              end

              # It was a newline; we've filled the row to the end, we
              # can move to the next row.
              next
            end

            # TODO
            # if (screen.full_unicode && content[ci - 1])
            if (content.try &.[ci - 1]?)
              # point = content.codepoint_at(ci - 1) # Unused
              # TODO
              # # Handle combining chars:
              # # Make sure they get in the same cell and are counted as 0.
              # if (unicode.combining[point])
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
              # end
              # Handle surrogate pairs:
              # Make sure we put surrogate pair chars in one cell.
              # if (point > 0x00ffff)
              #  ch = content[ci - 1] + content[ci]
              #  ci++
              # end
            end

            if @_no_fill
              next
            end

            if transparency = style.transparency
              lines[y][x].attr = Colors.blend(attr, lines[y][x].attr, alpha: transparency)
              if content[ci - 1]?
                lines[y][x].char = ch
              end
              lines[y].dirty = true
            else
              if cell != {attr, ch}
                lines[y][x].attr = attr
                lines[y][x].char = ch
                lines[y].dirty = true
              end
            end
          end
        end

        # Draw the scrollbar.
        # Could possibly draw this after all child elements.
        if (coords.notop || coords.nobot)
          i = -Int32::MAX
        end
        @scrollbar.try do # |scrollbar|
        # D O:
        # i = @get_scroll_height()
          i = Math.max @_clines.size, _scroll_bottom

          if ((yl - yi) < i)
            x = xl - 1
            if style.scrollbar.ignore_border? && @border
              x += 1
            end
            if @always_scroll
              y = @child_base / (i - (yl - yi))
            else
              y = (@child_base + @child_offset) / (i - 1)
            end
            y = yi + ((yl - yi) * y).to_i
            if (y >= yl)
              y = yl - 1
            end
            # XXX The '?' was added ad-hoc to prevent exceptions when something goes out of
            # bounds (e.g. size of widget given too small for content).
            # Is there any better way to handle?
            lines[y]?.try(&.[x]?).try do |cell|
              if @track
                ch = @style.track.char # || ' '
                attr = sattr style.track, style.track.fg, style.track.bg
                screen.fill_region attr, ch, x, x + 1, yi, yl
              end
              ch = style.scrollbar.char # || ' '
              attr = sattr style.scrollbar, style.scrollbar.fg, style.scrollbar.bg
              if cell != {attr, ch}
                cell.attr = attr
                cell.char = ch
                lines[y]?.try &.dirty=(true)
              end
            end
          end
        end

        if @border
          xi -= 1
          xl += 1
          yi -= 1
          yl += 1
        end

        if @padding.any?
          xi -= @padding.left
          xl += @padding.right
          yi -= @padding.top
          yl += @padding.bottom
        end

        # Draw the border.
        if border = @border
          battr = sattr style.border
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
            if border.type.line?
              if (x == xi)
                ch = '\u250c' # '┌'
                if (!border.left)
                  if (border.top)
                    ch = '\u2500'
                    # '─'
                  else
                    next
                  end
                else
                  if (!border.top)
                    ch = '\u2502'
                    # '│'
                  end
                end
              elsif (x == xl - 1)
                ch = '\u2510' # '┐'
                if (!border.right)
                  if (border.top)
                    ch = '\u2500'
                    # '─'
                  else
                    next
                  end
                else
                  if (!border.top)
                    ch = '\u2502'
                    # '│'
                  end
                end
              else
                ch = '\u2500'
                # '─'
              end
            elsif border.type.bg?
              ch = style.border.char
            end
            if (!border.top && x != xi && x != xl - 1)
              ch = ' '
              if cell != {dattr, ch}
                lines[y][x].attr = dattr
                lines[y][x].char = ch
                lines[y].dirty = true
                next
              end
            end
            if cell != {battr, ch}
              lines[y][x].attr = battr
              lines[y][x].char = ch ? ch : ' ' # XXX why ch can be nil?
              lines[y].dirty = true
            end
          end
          y = yi + 1
          while (y < yl - 1)
            if (!lines[y]?)
              break
            end
            cell = lines[y][xi]?
            if (cell)
              if (border.left)
                if border.type.line?
                  ch = '\u2502'
                  # '│'
                elsif border.type.bg?
                  ch = style.border.char
                end
                if (!coords.noleft)
                  if cell != {battr, ch}
                    lines[y][xi].attr = battr
                    lines[y][xi].char = ch ? ch : ' '
                    lines[y].dirty = true
                  end
                end
              else
                ch = ' '
                if cell != {dattr, ch}
                  lines[y][xi].attr = dattr
                  lines[y][xi].char = ch ? ch : ' '
                  lines[y].dirty = true
                end
              end
            end
            cell = lines[y][xl - 1]?
            if (cell)
              if (border.right)
                if border.type.line?
                  ch = '\u2502'
                  # '│'
                elsif border.type.bg?
                  ch = style.border.char
                end
                if (!coords.noright)
                  if cell != {battr, ch}
                    lines[y][xl - 1].attr = battr
                    lines[y][xl - 1].char = ch ? ch : ' '
                    lines[y].dirty = true
                  end
                end
              else
                ch = ' '
                if cell != {dattr, ch}
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
            if border.type.line?
              if (x == xi)
                ch = '\u2514' # '└'
                if (!border.left)
                  if (border.bottom)
                    ch = '\u2500'
                    # '─'
                  else
                    next
                  end
                else
                  if (!border.bottom)
                    ch = '\u2502'
                    # '│'
                  end
                end
              elsif (x == xl - 1)
                ch = '\u2518' # '┘'
                if (!border.right)
                  if (border.bottom)
                    ch = '\u2500'
                    # '─'
                  else
                    next
                  end
                else
                  if (!border.bottom)
                    ch = '\u2502'
                    # '│'
                  end
                end
              else
                ch = '\u2500'
                # '─'
              end
            elsif border.type.bg?
              ch = style.border.char
            end
            if (!border.bottom && x != xi && x != xl - 1)
              ch = ' '
              if cell != {dattr, ch}
                lines[y][x].attr = dattr
                lines[y][x].char = ch ? ch : ' '
                lines[y].dirty = true
              end
              next
            end
            if cell != {battr, ch}
              lines[y][x].attr = battr
              lines[y][x].char = ch ? ch : ' '
              lines[y].dirty = true
            end
          end
        end

        @shadow.try do |shadow|
          # right
          y = Math.max(yi + 1, 0)
          while (y < yl + 1)
            if (!lines[y]?)
              break
            end
            x = xl
            while (x < xl + 2)
              if (!lines[y][x]?)
                break
              end
              # D O:
              # lines[y][x].attr = Colors.blend(@dattr, lines[y][x].attr)
              lines[y][x].attr = Colors.blend(lines[y][x].attr, alpha: shadow)
              lines[y].dirty = true
              x += 1
            end
            y += 1
          end
          # bottom
          y = yl
          while (y < yl + 1)
            if (!lines[y]?)
              break
            end
            (Math.max(xi + 1, 0)...xl).each do |x2|
              if (!lines[y][x2]?)
                break
              end
              # D O:
              # lines[y][x].attr = Colors.blend(@dattr, lines[y][x].attr)
              lines[y][x2].attr = Colors.blend(lines[y][x2].attr, alpha: shadow)
              lines[y].dirty = true
            end
            y += 1
          end
        end

        if with_children
          @children.each do |el|
            if el.screen._ci != -1
              el.index = el.screen._ci
              el.screen._ci += 1
            end

            el.render
          end
        end

        emit Crysterm::Event::Render # , coords

        coords
      end

      def render(with_children = true)
        _render with_children
      end
    end

    include Position
    include Content
    include Rendering
    include Pos

    @@uid = 0

    # Unique ID. Auto-incremented.
    property uid : Int32

    # Widget's parent `Widget`, if any.
    property parent : Widget?

    # Screen owning this element.
    # Each element must belong to a Screen if it is to be rendered/displayed anywhere.
    property! screen : ::Crysterm::Screen?

    # Widget's render (order) index that was determined/used during the last `#render` call.
    property index = -1

    class_property style : Style = Style.new

    # Automatically position child elements with border and padding in mind.
    property auto_padding = true

    # ######## COMMON WITH SCREEN

    property? destroyed = false

    # Arbitrary widget name
    property name : String?

    # Storage for any miscellaneous data.
    property data : JSON::Any?

    getter children = [] of self

    # What action to take when widget would overflow parent's boundaries?
    property overflow = Overflow::Ignore

    # Draw shadow on the element's right and bottom? Can be `true` for opacity 0.5, or a specific Float.
    property shadow : Float64?

    # Is element hidden? Hidden elements are not rendered on the screen and their dimensions don't use screen space.
    property? hidden = false

    #
    private property? fixed = false

    # Horizontal text alignment
    property align : Tput::AlignFlag = Tput::AlignFlag::Top | Tput::AlignFlag::Left

    # Can element's content be word-wrapped?
    property? wrap = true

    # Can width/height be auto-adjusted during rendering based on content and child elements?
    property? resizable = false

    # Is element clickable?
    property? clickable = false

    # Can element receive keyboard input? (Managed internally; use `input` for user-side setting)
    property? keyable = false

    # Is element draggable?
    property? draggable = false

    # XXX FIX
    # Used only for lists
    property _is_list = false
    property? label = false
    property? interactive = false
    # XXX

    property? auto_focus = false

    property position : Tput::Position

    property? vi : Bool = false

    # XXX why are these here and not in @position?
    # property top = 0
    # property left = 0
    # setter width = 0
    # property height = 0
    def top
      _get_top false
    end

    def left
      _get_left false
    end

    def height
      _get_height false
    end

    def width
      _get_width false
    end

    # Does it accept keyboard input?
    property? input = false

    # Is element's content to be parsed for tags?
    property? parse_tags = true

    property? keys : Bool = false
    property? ignore_keys : Bool = false

    # START SCROLLABLE

    # Is element scrollable?
    property? scrollable = false

    property? scrollbar : Bool = false
    property? track : Bool = false

    # Offset from the top of content (in number of lines) due to scrolling.
    # E.g. 0 == no scroll (first line is visible/shown at the top), or
    # 5 == 5 lines are hidden due to scroll, 6th line of content is first to
    # be displayed.
    property child_base = 0

    # Offset of cursor (in number of lines) within Widget. Value of 0 means
    # cursor being at first line of visible (potentially scrolled) content.
    property child_offset = 0

    property base_limit = Int32::MAX

    property? always_scroll : Bool = false

    property _scroll_bottom : Int32 = 0

    # END SCROLLABLE

    property? _no_fill = false

    # Amount of padding on the inside of the element
    property padding : Padding

    # Widget's border.
    property border : Border?

    setter style : Style

    # Width of tabs in elements' content.
    property tab_size : Int32
    getter! tabc : String

    property _label : Widget?

    @ev_label_scroll : Crysterm::Event::Scroll::Wrapper?
    @ev_label_resize : Crysterm::Event::Resize::Wrapper?

    def initialize(
      *,
      # These end up being part of Position.
      # If position is specified, these are ignored.
      left = nil,
      top = nil,
      right = nil,
      bottom = nil,
      width = nil,
      height = nil,

      hidden = nil,
      @fixed = false,
      @wrap = true,
      @align = Tput::AlignFlag::Top | Tput::AlignFlag::Left,
      position : Tput::Position? = nil,
      resizable = nil,
      overflow : Overflow? = nil,
      shadow = nil,
      @style = Style.new, # Previously: Style? = nil
      padding : Padding | Int32 = 0,
      border = nil,
      # @clickable=false,
      content = "",
      label = nil,
      hover_text = nil,
      scrollable = nil,
      # hover_bg=nil,
      @draggable = false,
      focused = false,

      # synonyms
      @parse_tags = true,

      auto_focus = false,

      scrollbar = nil,
      track = nil,

      @parent = nil,
      @name = nil,
      @screen = determine_screen, # NOTE a todo item about this is in file TODO
      index = -1,
      children = [] of Widget,
      @auto_padding = true,
      @tab_size = ::Crysterm::TAB_SIZE,
      tabc = nil,
      @keys = false,
      input = nil
    )
      @tabc = tabc || (" " * @tab_size)
      resizable.try { |v| @resizable = v }
      hidden.try { |v| @hidden = v }
      scrollable.try { |v| @scrollable = v }
      overflow.try { |v| @overflow = v }
      shadow.try { |v| @shadow = v.is_a?(Bool) ? (v ? 0.5 : nil) : v }

      scrollbar.try { |v| @scrollbar = v }
      track.try { |v| @track = v }
      input.try { |v| @input = v }

      @uid = next_uid

      # Allow name to be nil, to avoid creating strings
      # @name = name || "#{self.class.name}-#{@uid}"

      # $ = _ = JSON/YAML::Any

      if position
        @position = position
      else
        @position = Tput::Position.new \
          left: left,
          top: top,
          right: right,
          bottom: bottom,
          width: width,
          height: height
      end
      @resizable = true if @position.resizable?

      case padding
      when Int
        @padding = Padding.new padding, padding, padding, padding
      when Padding
        @padding = padding
      else
        raise "Invalid padding argument"
      end

      @border = case border
                when true
                  Border.new BorderType::Line
                when nil, false
                  # Nothing
                when BorderType
                  Border.new border
                when Border
                  border
                else
                  raise "Invalid border argument"
                end

      # Add element to parent
      if parent = @parent
        parent.append self
        # elsif screen # XXX Don't do; see above for arg screen, and see TODO file
        #  screen.try &.append self
      end

      children.each do |child|
        append child
      end

      set_content(content, true)
      set_label(label, "left") if label
      set_hover(hover_text) if hover_text

      # on(AddHandlerEvent) { |wrapper| }
      on(Crysterm::Event::Resize) { parse_content }
      on(Crysterm::Event::Attach) { parse_content }
      # on(Crysterm::Event::Detach) { @lpos = nil } # XXX D O or E O?

      if s = scrollbar
        # Allow controlling of the scrollbar via the mouse:
        # TODO
        # if @mouse
        #  # TODO
        # end
      end

      # # TODO same as above
      # if @mouse
      # end

      if @keys && !@ignore_keys
        on(Crysterm::Event::KeyPress) do |e|
          key = e.key
          ch = e.char

          if (key == Tput::Key::Up || (@vi && ch == 'k'))
            scroll(-1)
            screen.render
            next
          end
          if (key == Tput::Key::Down || (@vi && ch == 'j'))
            scroll(1)
            screen.render
            next
          end

          if @vi
            # XXX remove all those protections for height being Int
            case key
            when Tput::Key::CtrlU
              height.try do |h|
                next unless h.is_a? Int
                offs = -h // 2
                scroll offs == 0 ? -1 : offs
                screen.render
              end
              next
            when Tput::Key::CtrlD
              height.try do |h|
                next unless h.is_a? Int
                offs = h // 2
                scroll offs == 0 ? 1 : offs
                screen.render
              end
              next
            when Tput::Key::CtrlB
              height.try do |h|
                next unless h.is_a? Int
                offs = -h
                scroll offs == 0 ? -1 : offs
                screen.render
              end
              next
            when Tput::Key::CtrlF
              height.try do |h|
                next unless h.is_a? Int
                offs = h
                scroll offs == 0 ? 1 : offs
                screen.render
              end
              next
            end

            case ch
            when 'g'
              scroll_to 0
              screen.render
              next
            when 'G'
              scroll_to get_scroll_height
              screen.render
              next
            end
          end
        end
      end

      if @scrollable
        # XXX also remove handler when scrollable is turned off?
        on(Crysterm::Event::ParsedContent) do
          _recalculate_index
        end

        _recalculate_index
      end

      focus if focused
    end

    def style
      focused? ? (@style.focus || @style) : @style
    end

    # Potentially use this where ever .scrollable? is used
    def really_scrollable?
      return @scrollable if @resizable
      get_scroll_height > height
    end

    def get_scroll
      @child_base + @child_offset
    end

    def scroll_to(offset, always = false)
      scroll 0
      scroll offset - (@child_base + @child_offset), always
    end

    # alias_previous :set_scroll

    def _recalculate_index
      return 0 if !@screen || !@scrollable

      # D O
      # XXX
      # max = get_scroll_height - (height - iheight)

      max = @_clines.size - (height - iheight)
      max = 0 if max < 0
      emax = @_scroll_bottom - (height - iheight)
      emax = 0 if emax < 0

      @child_base = Math.min @child_base, Math.max emax, max

      if @child_base < 0
        @child_base = 0
      elsif @child_base > @base_limit
        @child_base = @base_limit
      end
    end

    def get_scroll_height
      Math.max @_clines.size, @_scroll_bottom
    end

    def set_scroll_perc(i)
      # D O
      # XXX
      # m = @get_scroll_height
      m = Math.max @_clines.size, @_scroll_bottom
      scroll_to ((i / 100) * m).to_i
    end

    def reset_scroll
      return unless @scrollable
      @child_offset = 0
      @child_base = 0
      emit Crysterm::Event::Scroll
    end

    def get_scroll_perc(s)
      pos = @lpos || @_get_coords
      if !pos
        return s ? -1 : 0
      end

      height = (pos.yl - pos.yi) - iheight
      i = get_scroll_height
      # p

      if (height < i)
        if @always_scroll
          p = @child_base / (i - height)
        else
          p = (@child_base + @child_offset) / (i - 1)
        end
        return p * 100
      end

      s ? -1 : 0
    end

    def _scroll_bottom
      return 0 unless @scrollable

      # We could just calculate the children, but we can
      # optimize for lists by just returning the items.length.
      if @_is_list
        return @items ? @items.size : 0
      end

      @lpos.try do |lpos|
        if lpos._scroll_bottom != 0
          return lpos._scroll_bottom
        end
      end

      bottom = @children.reduce(0) do |current, el|
        # el.height alone does not calculate the shrunken height, we need to use
        # get_coords. A shrunken box inside a scrollable element will not grow any
        # larger than the scrollable element's context regardless of how much
        # content is in the shrunken box, unless we do this (call get_coords
        # without the scrollable calculation):
        # See: $ test/widget-shrink-fail-2
        if @screen
          lpos = el._get_coords false, true
          if lpos
            return Math.max(current, el.rtop + (lpos.yl - lpos.yi))
          end
        end
        return Math.max(current, el.rtop + el.height)
      end

      # XXX Use this? Makes .get_scroll_height useless
      # if bottom < @_clines.size
      #   bottom = @_clines.size
      # end

      @lpos.try do |lpos|
        lpos._scroll_bottom = bottom
      end

      bottom
    end

    # Scrolls widget by `offset` lines down or up
    def scroll(offset, always = false)
      return unless @scrollable
      return unless @screen

      # Handle scrolling.
      # visible == amount of actual content lines visible in the widget. E.g. for
      # a widget of height=4 and border (which renders within height), the amount
      # of visible lines == 2.
      visible = height - iheight
      # Current scrolling amount, i.e. the index of the first line of content which
      # is actually shown. (base == 2 means content is showing from its 3rd line onwards)
      base = @child_base

      if @always_scroll || always
        # Semi-workaround
        @child_offset = offset > 0 ? visible - 1 + offset : offset
      else
        @child_offset += offset
      end

      if (@child_offset > visible - 1)
        d = @child_offset - (visible - 1)
        @child_offset -= d
        @child_base += d
      elsif (@child_offset < 0)
        d = @child_offset
        @child_offset += -d
        @child_base += d
      end

      if (@child_base < 0)
        @child_base = 0
      elsif (@child_base > @base_limit)
        @child_base = @base_limit
      end

      # Find max "bottom" value for
      # content and descendant elements.
      # Scroll the content if necessary.
      if (@child_base == base)
        return emit Crysterm::Event::Scroll
      end

      # When scrolling text, we want to be able to handle SGR codes as well as line
      # feeds. This allows us to take preformatted text output from other programs
      # and put it in a scrollable text box.
      parse_content

      # D O:
      # XXX
      # max = get_scroll_height - (height - iheight)

      max = @_clines.size - (height - iheight)
      if (max < 0)
        max = 0
      end
      emax = _scroll_bottom - (height - iheight)
      if (emax < 0)
        emax = 0
      end

      @child_base = Math.min @child_base, Math.max(emax, max)

      if (@child_base < 0)
        @child_base = 0
      elsif (@child_base > @base_limit)
        @child_base = @base_limit
      end

      # Optimize scrolling with CSR + IL/DL.
      p = @lpos
      # Only really need _getCoords() if we want
      # to allow nestable scrolling elements...
      # or if we **really** want shrinkable
      # scrolling elements.
      # p = @_get_coords
      if (p && @child_base != base && screen.clean_sides(self))
        t = p.yi + itop
        b = p.yl - ibottom - 1
        d = @child_base - base

        if (d > 0 && d < visible)
          # scrolled down
          screen.delete_line(d, t, t, b)
        elsif (d < 0 && -d < visible)
          # scrolled up
          d = -d
          screen.insert_line(d, t, t, b)
        end
      end

      emit Crysterm::Event::Scroll
    end

    # Sets widget label
    def set_label(text, side = "left")
      # If label exists, we update it and return
      @_label.try do |_label|
        _label.set_content(text)
        if side != "right"
          _label.rleft = 2 + (@border ? -1 : 0)
          _label.position.right = nil
          unless @auto_padding
            _label.rleft = 2
          end
        else
          _label.rright = 2 + (@border ? -1 : 0)
          _label.position.left = nil
          unless @auto_padding
            _label.rright = 2
          end
        end
        return
      end

      # Or if it doesn't exist, we create it
      @_label = _label = Widget::Box.new(
        parent: self,
        content: text,
        top: -itop,
        parse_tags: @parse_tags,
        resizable: true,
        style: @style.label,
              # border: true,
        # height: 1
)

      if side != "right"
        _label.rleft = 2 - ileft
      else
        _label.rright = 2 - iright
      end

      _label.label = true

      unless @auto_padding
        if side != "right"
          _label.rleft = 2
        else
          _label.rright = 2
        end
        _label.rtop = 0
      end

      @ev_label_scroll = on Crysterm::Event::Scroll, ->reposition(Crysterm::Event::Scroll)
      @ev_label_resize = on Crysterm::Event::Resize, ->reposition(Crysterm::Event::Resize)
    end

    # Removes widget label
    def remove_label
      return unless @_label
      off ::Crysterm::Event::Scroll, @ev_label_scroll
      off ::Crysterm::Event::Resize, @ev_label_resize
      @_label.deparent
      @ev_label_scroll = nil
      @ev_label_resize = nil
      @_label = nil
    end

    def reposition(event = nil)
      @_label.try do |_label|
        _label.rtop = @child_base - itop
        unless @auto_padding
          _label.rtop = @child_base
        end
        screen.render
      end
    end

    def set_hover(hover_text)
    end

    def remove_hover
    end

    # Hides widget from screen
    def hide
      return if @hidden
      clear_pos
      @hidden = true
      emit Crysterm::Event::Hide
      # screen.rewind_focus if focused?
      screen.rewind_focus if screen.focused == self
    end

    # Shows widget on screen
    def show
      return unless @hidden
      @hidden = false
      emit Crysterm::Event::Show
    end

    # Toggles widget visibility
    def toggle_visibility
      @hidden ? show : hide
    end

    # Puts current widget in focus
    def focus
      # XXX Prevents getting multiple `Event::Focus`s. Remains to be
      # seen whether that's good, or it should always happen, even
      # if someone calls `#focus` multiple times in a row.
      return if focused?
      screen.focused = self
    end

    # Returns whether widget is currently in focus
    @[AlwaysInline]
    def focused?
      screen.focused == self
    end

    # Returns whether widget is visible. This is different from `#hidden?`
    # because it checks the complete chain of widget parents.
    def visible?
      el = self
      while el
        return false unless el.screen
        return false if el.hidden?
        el = el.parent
      end
      true
    end

    def draggable?
      @_draggable
    end

    def draggable=(draggable : Bool)
      draggable ? enable_drag(draggable) : disable_drag
    end

    def enable_drag(x)
      @_draggable = true
    end

    def disable_drag
      @_draggable = false
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

    # Sends widget to front
    def front!
      set_index -1
    end

    # Sends widget to back
    def back!
      set_index 0
    end

    def self.sattr(style : Style, fg = nil, bg = nil)
      if fg.nil? && bg.nil?
        fg = style.fg
        bg = style.bg
      end

      # This used to be a loop, but I decided
      # to unroll it for performance's sake.
      # TODO implement this -- i.e. support style.* being Procs ?

      # D O:
      # return (this.uid << 24)
      #   | ((this.dockBorders ? 32 : 0) << 18)
      ((style.invisible ? 16 : 0) << 18) |
        ((style.inverse ? 8 : 0) << 18) |
        ((style.blink ? 4 : 0) << 18) |
        ((style.underline ? 2 : 0) << 18) |
        ((style.bold ? 1 : 0) << 18) |
        (Colors.convert(fg) << 9) |
        Colors.convert(bg)
    end

    def sattr(style : Style, fg = nil, bg = nil)
      self.class.sattr style, fg, bg
    end

    def free
      # TODO Remove all listeners? etc.
    end

    def screenshot(xi = nil, xl = nil, yi = nil, yl = nil)
      xi = @lpos.xi + ileft + (xi || 0)
      if xl
        xl = @lpos.xi + ileft + (xl || 0)
      else
        xl = @lpos.xl - iright
      end

      yi = @lpos.yi + itop + (yi || 0)
      if yl
        yl = @lpos.yi + itop + (yl || 0)
      else
        yl = @lpos.yl - ibottom
      end

      screen.screenshot xi, xl, yi, yl
    end

    # :nodoc:
    # no-op in this place
    def _update_cursor(arg)
    end

    # Removes node from its parent.
    # This is identical to calling `#remove` on the parent object.
    def deparent
      @parent.try { |p| p.remove self }
    end

    # Appends `element` to list of children
    def append(element)
      insert element
    end

    # Appends `element`s to list of children in order of specification
    def append(*elements)
      elements.each do |el|
        insert el
      end
    end

    # Inserts `element` to list of children at a specified position (at end by default)
    def insert(element, i = -1)
      if element.screen != screen
        raise Exception.new("Cannot switch a node's screen.")
      end

      element.deparent

      # if i == -1
      #  @children.push element
      # elsif i == 0
      #  @children.unshift element
      # else
      @children.insert i, element
      # end

      element.parent = self

      screen.try &.attach(element)

      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element
    end

    def remove(element)
      return if element.parent != self

      return unless i = @children.index(element)

      element.clear_pos

      element.parent = nil
      @children.delete_at i

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

      screen.try &.detach(element)

      if screen.focused == element
        screen.rewind_focus
      end
    end

    # Prepends node to the list of children
    def prepend(element)
      insert element, 0
    end

    # Adds node to the list of children before the specified `other` element
    def insert_before(element, other)
      if i = @children.index other
        insert element, i
      end
    end

    # Adds node to the list of children after the specified `other` element
    def insert_after(element, other)
      if i = @children.index other
        insert element, i + 1
      end
    end

    def next_uid
      @@uid += 1
    end

    def determine_screen
      win = if Screen.total <= 1
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
            elsif Screen.total > 0
              Screen.instances[-1]
            end

      unless win
        raise Exception.new("No Screen found anywhere. Create one with Screen.new")
      end

      win
    end

    # Returns parent `Widget` (if any) or `Screen` to which the widget may be attached.
    # If the widget already is `Screen`, returns `nil`.
    def parent_or_screen
      return nil if Screen === self
      @parent || screen
    end

    def destroy
      @children.each do |c|
        c.destroy
      end
      deparent
      @destroyed = true
      emit Crysterm::Event::Destroy
    end

    # TODO
    # get/set functions for data JSON

    # Nop for the basic class
    def free
    end

    def ancestor?(obj)
      el = self
      while el = el.parent
        return true if el == obj
      end
      false
    end

    def descendant?(obj)
      @children.each do |el|
        return true if el == obj
        return true if el.descendant? obj
      end
      false
    end

    def each_descendant(with_self : Bool = false, &block : Proc(Widget, Nil)) : Nil
      block.call(self) if with_self

      f = uninitialized Widget -> Nil
      f = ->(el : Widget) {
        block.call el
        el.children.each do |c|
          f.call c
        end
      }

      @children.each do |el|
        f.call el
      end
    end

    def each_ancestor(with_self : Bool = false) : Nil
      yield self if with_self

      el = self
      while el = el.parent
        yield el
      end
    end

    def collect_descendants(el : Widget) : Array(Widget)
      children = [] of Widget
      each_descendant { |e| children << e }
      children
    end

    def collect_ancestors(el : Widget) : Array(Widget)
      parents = [] of Widget
      each_ancestor { |e| parents << e }
      parents
    end

    # Emits `ev` on all children nodes, recursively.
    def emit_descendants(ev : EventHandler::Event) : Nil
      each_descendant { |e| el.emit e }
    end

    # Emits `ev` on all parent nodes.
    def emit_ancestors(ev : EventHandler::Event) : Nil
      each_ancestor { |e| el.emit e }
    end
  end
end
