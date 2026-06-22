require "./box"

module Crysterm
  class Layout
    # Vertical box layout (cf. Qt's `QVBoxLayout`). Lays children out
    # top-to-bottom; children without an explicit `height` share the leftover
    # space equally, and children without an explicit `width` fill the interior
    # width. See `Layout::Box`.
    class VBox < Box
      def initialize(gap : Int32 = 0)
        super Orientation::Vertical, gap
      end
    end
  end
end
