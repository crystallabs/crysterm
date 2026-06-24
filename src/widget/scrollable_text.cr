require "./scrollable_box"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![ScrollableText screenshot](../../examples/widget/scrollable_text/scrollable_text-capture.png)
    # <!-- /widget-examples:capture -->
    class ScrollableText < ScrollableBox
      @always_scroll = true
    end
  end
end
