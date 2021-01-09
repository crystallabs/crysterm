require "./node"

module Crysterm
  module Widget
    # Abstract input element
    class ScrollableText < ScrollableBox
      @always_scroll = true
    end
  end
end
