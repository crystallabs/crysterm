module Crysterm
  class Widget
    # Widget's position in the stack (front, back). Render index / order.

    property index = -1

    # Sends widget to front
    def front!
      set_index -1
    end

    # Sends widget to back
    def back!
      set_index 0
    end

    def set_index(index : Int)
      return unless parent = @parent

      if index < 0
        index = parent.children.size + index
      end

      index = Math.max index, 0
      index = Math.min index, parent.children.size - 1

      i = parent.children.index self

      return unless i

      parent.children.insert index, parent.children.delete_at i

      true
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
  end
end
