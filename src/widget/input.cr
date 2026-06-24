require "./box"

module Crysterm
  class Widget
    # Abstract input element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Input screenshot](../../examples/widget/input/input-capture.png)
    # <!-- /widget-examples:capture -->
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
              request_render
              next
            end
            if key == Tput::Key::Down || (@vi && ch == 'j')
              scroll(1)
              request_render
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
                  request_render
                end
                next
              when Tput::Key::CtrlD
                height.try do |h|
                  next unless h.is_a? Int
                  offs = h // 2
                  scroll offs == 0 ? 1 : offs
                  request_render
                end
                next
              when Tput::Key::CtrlB
                height.try do |h|
                  next unless h.is_a? Int
                  offs = -h
                  scroll offs == 0 ? -1 : offs
                  request_render
                end
                next
              when Tput::Key::CtrlF
                height.try do |h|
                  next unless h.is_a? Int
                  offs = h
                  scroll offs == 0 ? 1 : offs
                  request_render
                end
                next
              end

              case ch
              when 'g'
                scroll_to 0
                request_render
                next
              when 'G'
                scroll_to get_scroll_height
                request_render
                next
              end
            end
          end
        end
      end
    end
  end
end
