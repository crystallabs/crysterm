module Crysterm
  class Screen < Node
    module Focus
      include Crystallabs::Helpers::Alias_Methods

      def focus_offset(offset)
        shown = @keyable.select { |el| !el.detached? && el.visible? }.size

        if (shown == 0 || offset == 0)
          return
        end

        i = @keyable.index(focused) || return

        if (offset > 0)
          while offset > 0
            offset -= 1
            i += 1
            if (i > @keyable.size - 1)
              i = 0
            end
            if (@keyable[i].detached? || !@keyable[i].visible?)
              offset += 1
            end
          end
        else
          offset = -offset
          while offset > 0
            offset -= 1
            i -= 1
            if (i < 0)
              i = @keyable.size - 1
            end
            if (@keyable[i].detached? || !@keyable[i].visible?)
              offset += 1
            end
          end
        end

        @keyable[i].focus
      end

      def focus_previous
        focus_offset -1
      end

      alias_previous focus_prev

      def focus_next
        focus_offset 1
      end

      def save_focus
        @_saved_focus = focused
      end

      def restore_focus
        return unless sf = @_saved_focus
        sf.focus
        @_saved_focus = nil
        focused
      end

      def focus_push(el)
        return if !el
        old = @history[-1]?
        while @history.size >= 10
          @history.shift
        end
        @history.push el
        _focus el, old
      end

      def focus_pop
        old = @history.pop
        if el = @history[-1]?
          _focus el, old
        end
        return old
      end

      def rewind_focus
        old = @history.pop

        while @history.size > 0
          el = @history.pop
          if !el.detached? && el.visible?
            @history.push el
            _focus el, old
            return el
          end
        end

        if old
          old.emit BlurEvent
        end
      end

      def _focus(cur : Element, old : Element? = nil)
        # Find a scrollable ancestor if we have one.
        el = cur
        while el = el.parent
          if el.scrollable?
            break
          end
        end

        # TODO is it valid that this isn't Element?
        # unless el.is_a? Element
        #  raise "Unexpected"
        # end

        # If we're in a scrollable element,
        # automatically scroll to the focused element.
        if (el && !el.detached?)
          # NOTE: This is different from the other "visible" values - it needs the
          # visible height of the scrolling element itself, not the element within it.
          visible = cur.screen.height - el.atop.not_nil! - el.itop.not_nil! - el.abottom.not_nil! - el.ibottom.not_nil!
          if cur.rtop < el.child_base
            # TODO Enable
            # el.scroll_to cur.rtop
            cur.screen.render
          elsif (cur.rtop + cur.height - cur.ibottom) > (el.child_base + visible)
            # Explanation for el.itop here: takes into account scrollable elements
            # with borders otherwise the element gets covered by the bottom border:
            # TODO Enable
            # el.scroll_to cur.rtop - (el.height - cur.height) + el.itop, true
            cur.screen.render
          end
        end

        if old
          old.emit BlurEvent, cur
        end

        cur.emit FocusEvent, old
      end

      def focused
        @history[-1]?
      end

      def focused=(el)
        focus_push el
      end
    end
  end
end
