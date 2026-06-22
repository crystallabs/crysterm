require "./box"

module Crysterm
  class Layout
    # Horizontal box layout (cf. Qt's `QHBoxLayout`). Lays children out
    # left-to-right; children without an explicit `width` share the leftover
    # space equally, and children without an explicit `height` fill the
    # interior height. See `Layout::Box`.
    class HBox < Box
      def initialize(gap : Int32 = 0)
        super Orientation::Horizontal, gap
      end
    end
  end
end
