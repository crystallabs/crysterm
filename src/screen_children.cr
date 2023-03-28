module Crysterm
  class Screen
    def insert(element, i = -1)
      # Prevents adding an element twice
      super || return

      attach element

      # XXX:
      # - Do similar for mouse as well
      # - Make sure this is undo-ed if widget is detached
      if element.input? || element.keyable?
        _listen_keys element
      end

      unless self.focused
        # element.focus
        focus_next
      end
    end

    # :ditto:
    def <<(element)
      insert element
    end

    def remove(element)
      return if element.screen != self

      super

      # TODO Enable
      # if i = @display.clickable.index(element)
      #  @display.clickable.delete_at i
      # end
      # if i = @display.keyable.index(element)
      #  @display.keyable.delete_at i
      # end

      # s= @display
      # raise Exception.new() unless s
      # screen_clickable= s.clickable
      # screen_keyable= s.keyable

      detach element

      if focused == element
        rewind_focus
      end
    end

    # :ditto:
    def >>(element)
      remove element
    end

    def attach(element)
      # Adding an element to Screen consists of setting #screen= (self) on that element
      # and all of its children. Attach/Detach events are emitted accordingly. Attaching
      # if already attached is a no-op.
      element.self_and_each_descendant do |el|
        if scr = el.screen?
          if scr != self
            el.screen = nil
            el.emit Crysterm::Event::Detach, scr
          end
        end

        if !el.screen?
          el.screen = self
          el.emit Crysterm::Event::Attach, self
        end
      end
    end

    def detach(element)
      element.self_and_each_descendant do |el|
        if scr = el.screen
          el.screen = nil
          el.emit Crysterm::Event::Detach, scr
        end
      end
    end
  end
end
