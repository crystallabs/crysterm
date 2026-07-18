require "./box"

module Crysterm
  class Layout
    # Vertical box layout (cf. Qt's `QVBoxLayout`). Lays children out
    # top-to-bottom; children without an explicit `height` share the leftover
    # space by their `stretch` factor, and (with the default `align: Stretch`)
    # those without an explicit `width` fill the interior width.
    #
    # <!-- widget-examples:capture v1 -->
    # ![VBox screenshot](../../tests/layout/vbox/vbox.5s.apng)
    # <!-- /widget-examples:capture -->
    class VBox < Box
      def initialize(spacing : Int32 = 0, justify : Justify = Justify::Start, align : Align = Align::Stretch)
        super Tput::Orientation::Vertical, spacing, justify, align
      end
    end
  end
end
