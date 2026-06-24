require "./box"

module Crysterm
  class Layout
    # Vertical box layout (cf. Qt's `QVBoxLayout`). Lays children out
    # top-to-bottom; children without an explicit `height` share the leftover
    # space by their `grow` factor, and (with the default `align: Stretch`)
    # those without an explicit `width` fill the interior width. See
    # `Layout::Box`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![VBox screenshot](../../examples/layout/vbox/vbox-capture.png)
    # <!-- /widget-examples:capture -->
    class VBox < Box
      def initialize(gap : Int32 = 0, justify : Justify = Justify::Start, align : Align = Align::Stretch)
        super Orientation::Vertical, gap, justify, align
      end
    end
  end
end
