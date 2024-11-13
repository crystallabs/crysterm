require "./box"

module Crysterm
  class Widget
    # Abstract input element
    class Input < Box
      @input = true
      @resizable = true

      def initialize(*arg, **kwarg)
        super

        if @keys && !@ignore_keys
          on(Crysterm::Event::KeyPress) do |e|
            key = e.key
            ch = e.char

            if key == Tput::Key::Up || (@vi && ch == 'k')
              scroll(-1)
              self.screen.render
              next
            end
            if key == Tput::Key::Down || (@vi && ch == 'j')
              scroll(1)
              self.screen.render
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
                  self.screen.render
                end
                next
              when Tput::Key::CtrlD
                height.try do |h|
                  next unless h.is_a? Int
                  offs = h // 2
                  scroll offs == 0 ? 1 : offs
                  self.screen.render
                end
                next
              when Tput::Key::CtrlB
                height.try do |h|
                  next unless h.is_a? Int
                  offs = -h
                  scroll offs == 0 ? -1 : offs
                  self.screen.render
                end
                next
              when Tput::Key::CtrlF
                height.try do |h|
                  next unless h.is_a? Int
                  offs = h
                  scroll offs == 0 ? 1 : offs
                  self.screen.render
                end
                next
              end

              case ch
              when 'g'
                scroll_to 0
                self.screen.render
                next
              when 'G'
                scroll_to get_scroll_height
                self.screen.render
                next
              end
            end
          end
        end
      end
    end
  end
end
