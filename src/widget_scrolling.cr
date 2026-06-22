module Crysterm
  class Widget
    # Is element scrollable?
    property? scrollable = false

    # Whether the widget position is fixed even in presence of scroll?
    # (Primary use in widget labels, which are always e.g. on top-left)
    private property? fixed = false

    property? scrollbar : Bool = false

    # Should widget indicate the scroll position?
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

    @ev_label_scroll : Crysterm::Event::Scroll::Wrapper?

    # Potentially use this where ever .scrollable? is used
    def really_scrollable?
      return @scrollable if @resizable
      get_scroll_height > aheight
    end

    # Returns total amount of lines by which widget is scrolled.
    #
    # The value combines invisible and visible parts. E.g. if a widget is scrolled
    # by 6 lines which are invisible (out of screen), and the cursor is at the 5th
    # line of visible content, `get_scroll` will return 11.
    def get_scroll
      @child_base + @child_offset
    end

    def scroll_to(offset, always = false)
      scroll 0
      scroll offset - (@child_base + @child_offset), always
    end

    def get_scroll_height
      Math.max @_clines.size, _scroll_bottom
    end

    def set_scroll_perc(i)
      m = get_scroll_height
      scroll_to ((i / 100) * m).to_i
    end

    def reset_scroll
      return unless @scrollable
      @child_offset = 0
      @child_base = 0
      emit Crysterm::Event::Scroll
    end

    def get_scroll_perc(s)
      # `_get_coords` (method call), not `@_get_coords` (a nonexistent ivar).
      pos = @lpos || _get_coords
      if !pos
        return s ? -1 : 0
      end

      height = (pos.yl - pos.yi) - iheight
      i = get_scroll_height
      # p

      if height < i
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
        return @items.any? ? @items.size : 0
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
        el_bottom = if el.screen? && (lpos = el._get_coords false, true)
                      el.rtop + (lpos.yl - lpos.yi)
                    else
                      el.rtop + el.aheight
                    end
        Math.max current, el_bottom
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
    def scroll(offset = 1, always = false)
      return unless @scrollable
      return unless screen?

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

      if @child_offset > visible - 1
        d = @child_offset - (visible - 1)
        @child_offset -= d
        @child_base += d
      elsif @child_offset < 0
        d = @child_offset
        @child_offset += -d
        @child_base += d
      end

      clamp_child_base

      # Find max "bottom" value for
      # content and descendant elements.
      # Scroll the content if necessary.
      if @child_base == base
        return emit Crysterm::Event::Scroll
      end

      # When scrolling text, we want to be able to handle SGR codes as well as line
      # feeds. This allows us to take preformatted text output from other programs
      # and put it in a scrollable text box.
      process_content

      clamp_child_base_to_content

      # Optimize scrolling with CSR + IL/DL.
      p = @lpos
      # Only really need _get_coords() if we want
      # to allow nestable scrolling elements...
      # or if we **really** want shrinkable
      # scrolling elements.
      # p = _get_coords
      if p && (@child_base != base) && screen.clean_sides(self)
        t = p.yi + itop
        b = p.yl - ibottom - 1
        d = @child_base - base

        if d > 0 && d < visible
          # scrolled down
          screen.delete_line(d, t, t, b)
        elsif d < 0 && -d < visible
          # scrolled up
          d = -d
          screen.insert_line(d, t, t, b)
        end
      end

      emit Crysterm::Event::Scroll
    end

    # Clamps `@child_base` into the valid `[0, @base_limit]` range. Kept as an
    # explicit branch (rather than `.clamp`) so it never raises even if
    # `@base_limit` is set below 0, exactly matching the original inline form.
    private def clamp_child_base
      if @child_base < 0
        @child_base = 0
      elsif @child_base > @base_limit
        @child_base = @base_limit
      end
    end

    # Pulls `@child_base` down to the largest valid scroll offset for the current
    # content — the greater of the wrapped-content height (`@_clines.size`) and
    # the descendant extent (`_scroll_bottom`), each measured against the visible
    # inner height — then re-clamps into `[0, @base_limit]`. Shared by `#scroll`
    # and `#_recalculate_index`, which had identical copies of this.
    private def clamp_child_base_to_content
      visible = aheight - iheight

      max = @_clines.size - visible
      max = 0 if max < 0
      emax = _scroll_bottom - visible
      emax = 0 if emax < 0

      @child_base = Math.min @child_base, Math.max(emax, max)

      clamp_child_base
    end

    def _recalculate_index
      return 0 if !screen? || !@scrollable

      clamp_child_base_to_content
    end
  end
end
