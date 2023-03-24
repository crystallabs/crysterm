module Crysterm
  class Widget
    # Is element scrollable?
    property? scrollable = false

    # Whether the widget position is fixed even in presence of scroll?
    # (Primary use in widget labels, which are always e.g. on top-left)
    private property? fixed = false

    property? scrollbar : Bool = false

    # Inside scrollbar (if enabled), should widget indicate the scroll position?
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

    @ev_label_scroll : Crysterm::Event::Scroll::Wrapper?

    # Potentially use this where ever .scrollable? is used
    def really_scrollable?
      return @scrollable if @resizable
      get_scroll_height > aheight
    end

    def get_scroll
      @child_base + @child_offset
    end

    def scroll_to(offset, always = false)
      scroll 0
      scroll offset - (@child_base + @child_offset), always
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
        # el.aheight alone does not calculate the shrunken height, we need to use
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
        return Math.max(current, el.rtop + el.aheight)
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
      visible = aheight - iheight
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
      process_content

      # D O:
      # XXX
      # max = get_scroll_height - (aheight - iheight)

      max = @_clines.size - (aheight - iheight)
      if (max < 0)
        max = 0
      end
      emax = _scroll_bottom - (aheight - iheight)
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
  end
end
