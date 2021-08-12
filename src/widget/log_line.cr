require "./scrollable_text"

module Crysterm
  class Widget
    class LogLine < ScrollableText
      property scroll_percentage = 0

      def initialize(@scroll_on_input = false, @scrollback = Int32::MAX, **scrollable_text)
        super **scrollable_text

        on Crysterm::Event::SetContent, ->set_content(Crysterm::Event::SetContent)
      end

      def set_content(e)
        if !@_user_scrolled || @scroll_on_input
          self.scroll_percentage = 100
          @_user_scrolled = false
          screen.try &.render
        end
      end

      def add(*args)
        # text = util.format.apply(util, args); # TODO
        text = args.inspect

        emit Crysterm::Event::LogLine, text

        ret = push_line text

        if @_clines.fake.size > @scrollback
          shift_line @scrollback // 3
        end

        ret
      end

      def scroll(offset, always)
        if offset == 0
          return super offset, always
        end

        @_user_scrolled = true

        ret = super offset, always

        if scroll_percentage == 100
          @_user_scrolled = false
        end

        ret
      end
    end
  end
end
