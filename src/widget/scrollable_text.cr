require "./node"

module Crysterm
  module Widget
    # Abstract input element
    class ScrollableText < ScrollableBox
      @type = :"scrollable-text"
      @always_scroll = true
    end
  end
end
