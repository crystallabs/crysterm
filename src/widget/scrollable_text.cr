require "./scrollable_box"

module Crysterm
  class Widget
    class ScrollableText < ScrollableBox
      @always_scroll = true
    end
  end
end
