module Crysterm
  class Screen
    # Widget focus.
    #
    # Broader in scope than mouse focus, since widget focus can be affected
    # by keys (Tab/Shift+Tab etc.) and operate without mouse.

    # Send focus events after mouse is enabled?
    property send_focus = false

    property _saved_focus : Widget?

    @history = [] of Widget
    @clickable = [] of Widget
    @keyable = [] of Widget

    # Returns the current/top element from the focus history list.
    def focused : Widget?
      @history[-1]?
    end

    # Makes `el` become the current/top element in the focus history list.
    def focus(el)
      focus_push el
    end

    # Focuses previous element in the list of focusable elements.
    def focus_previous
      focus_offset -1
    end

    # Focuses next element in the list of focusable elements.
    def focus_next
      focus_offset 1
    end

    # Saves/remembers the currently focused element.
    def save_focus
      @_saved_focus = focused
    end

    # Restores focus to the previously saved focused element.
    def restore_focus
      return unless sf = @_saved_focus
      sf.focus
      @_saved_focus = nil
      focused
    end

    # "Rewinds" focus to the most recent visible and attached element.
    #
    # As a side-effect, prunes the focus history list.
    def rewind_focus
      old = @history.pop

      el = @history.reverse.find { |el| el.screen && el.style.visible? }
      @history.clear

      return unless el

      if old
        old.emit Crysterm::Event::Blur
      end

      @history.push el
      _focus el, old
      el
    end

    # Focuses element `el`. Equivalent to `@display.focused = el`.
    def focus_push(el)
      old = @history.last?
      @history.shift if @history.size >= 10 # XXX non-configurable at the moment
      @history.push el
      _focus el, old
    end

    # Removes focus from the current element and focuses the element that was previously in focus.
    def focus_pop
      old = @history.pop
      if el = @history.last?
        _focus el, old
      end
      old
    end

    # Focuses an element by an offset in the list of focusable elements.
    #
    # E.g. `focus_offset 1` moves focus to the next focusable element.
    # `focus_offset 3` moves focus 3 focusable elements further.
    #
    # If the end of list of focusable elements is reached before the
    # item to focus is found, the search continues from the beginning.
    def focus_offset(offset)
      return if offset.zero?

      shown = @keyable.count { |el| el.screen && el.style.visible? }
      return if shown.zero?

      i = @keyable.index(focused) || -1
      i += offset

      i %= @keyable.size
      while !@keyable[i].screen || !@keyable[i].style.visible?
        i += offset >= 0 ? 1 : -1
        i %= @keyable.size
      end

      focus @keyable[i]
    end

    def _focus(cur : Widget, old : Widget? = nil)
      # Find a scrollable ancestor if we have one.
      el = cur
      while el = el.parent
        if el.scrollable?
          break
        end
      end

      # TODO is it valid that this isn't Widget?
      # unless el.is_a? Widget
      #  raise "Unexpected"
      # end

      # TODO temporary
      cur.try &.state = WidgetState::Focused
      old.try &.state = WidgetState::Normal

      # If we're in a scrollable element,
      # automatically scroll to the focused element.
      if el && el.screen
        # Note: This is different from the other "visible" values - it needs the
        # visible height of the scrolling element itself, not the element within it.
        # NOTE why a/i values can be nil?
        visible = cur.screen.aheight - (el.atop || 0) - (el.itop || 0) - (el.abottom || 0) - (el.ibottom || 0)
        if cur.rtop < el.child_base
          # XXX remove 'if' when Screen is no longer parent of elements
          if el.is_a? Widget
            el.scroll_to cur.rtop
          end
          cur.screen.render
        elsif (cur.rtop + cur.aheight - cur.ibottom) > (el.child_base + visible)
          # Explanation for el.itop here: takes into account scrollable elements
          # with borders otherwise the element gets covered by the bottom border:
          # XXX remove 'if' when Screen is no longer parent of elements (Now it's not
          # so removing. Eventually remove this note altogether.)
          # if el.is_a? Widget
          el.scroll_to cur.rtop - (el.aheight - cur.aheight) + el.itop, true
          # end
          cur.screen.render
        end
      end

      if old
        old.emit Crysterm::Event::Blur, cur
      end

      cur.emit Crysterm::Event::Focus, old
    end
  end
end
