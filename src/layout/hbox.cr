require "./box"

module Crysterm
  class Layout
    # Horizontal box layout (cf. Qt's `QHBoxLayout`). Lays children out
    # left-to-right; children without an explicit `width` share the leftover
    # space by their `stretch` factor, and (with the default `align: Stretch`)
    # those without an explicit `height` fill the interior height.
    #
    # <!-- widget-examples:capture v1 -->
    # ![HBox screenshot](../../tests/layout/hbox/hbox.5s.apng)
    # <!-- /widget-examples:capture -->
    class HBox < Box
      def initialize(spacing : Int32 = 0, justify : Justify = Justify::Start, align : Align = Align::Stretch)
        super Tput::Orientation::Horizontal, spacing, justify, align
      end
    end
  end
end
