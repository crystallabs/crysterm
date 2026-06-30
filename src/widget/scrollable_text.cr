require "./scrollable_box"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![ScrollableText screenshot](../../tests/widget/scrollable_text/scrollable_text.5s.apng)
    # <!-- /widget-examples:capture -->
    class ScrollableText < ScrollableBox
      @always_scroll = true
    end
  end
end
