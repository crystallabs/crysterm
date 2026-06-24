require "./box"

module Crysterm
  class Layout
    # Horizontal box layout (cf. Qt's `QHBoxLayout`). Lays children out
    # left-to-right; children without an explicit `width` share the leftover
    # space by their `grow` factor, and (with the default `align: Stretch`)
    # those without an explicit `height` fill the interior height. See
    # `Layout::Box`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![HBox screenshot](../../examples/layout/hbox/hbox-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class HBox < Box
      def initialize(gap : Int32 = 0, justify : Justify = Justify::Start, align : Align = Align::Stretch)
        super Orientation::Horizontal, gap, justify, align
      end
    end
  end
end
