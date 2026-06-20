require "./scrollable_text"

module Crysterm
  class Widget
    class Log < ScrollableText
      # `scroll_percentage` must reflect/drive the real scroll position. It used
      # to be a plain `property` (inert Int), so `self.scroll_percentage = 100`
      # just stored 100 and never scrolled, and the `== 100` check below read a
      # stale constant. Delegate to the actual scroll-percentage methods.
      def scroll_percentage
        get_scroll_perc false
      end

      def scroll_percentage=(i)
        set_scroll_perc i
      end

      def initialize(@scroll_on_input = false, @scrollback = Int32::MAX, **scrollable_text)
        super **scrollable_text

        on Crysterm::Event::SetContent, ->set_content(Crysterm::Event::SetContent)
      end

      def set_content(e)
        if !@_user_scrolled || @scroll_on_input
          self.scroll_percentage = 100
          @_user_scrolled = false
          screen?.try &.render
        end
      end

      def add(*args)
        text = args.inspect

        emit Crysterm::Event::Log, text

        ret = push_line text

        if @_clines.fake.size > @scrollback
          shift_line @scrollback // 3
        end

        ret
      end

      # Defaults mirror the base `scroll(offset = 1, always = false)` so a
      # one-arg `scroll 0` (from `scroll_to`/`set_scroll_perc`) dispatches here
      # instead of silently falling through to the base method.
      def scroll(offset = 1, always = false)
        if offset == 0
          return super offset, always
        end

        @_user_scrolled = true

        ret = super offset, always

        # `scroll_percentage` is a float; use `>= 100` rather than `== 100` so a
        # bottom position that computes to e.g. 99.999 still re-enables
        # auto-scroll instead of getting stuck with `@_user_scrolled` true.
        if scroll_percentage >= 100
          @_user_scrolled = false
        end

        ret
      end
    end
  end
end
