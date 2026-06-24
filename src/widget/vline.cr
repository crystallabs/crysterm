require "./line"

module Crysterm
  class Widget
    # Vertical line
    #
    # <!-- widget-examples:capture v1 -->
    # ![VLine screenshot](../../examples/widget/vline/vline-capture.png)
    # <!-- /widget-examples:capture -->
    class VLine < Line
      @orientation = :vertical

      def initialize(**line)
        super @orientation, **line
      end
    end

    # <!-- widget-examples:capture v1 -->
    # ![VLine screenshot](../../examples/widget/vline/vline-capture.png)
    # <!-- /widget-examples:capture -->
    alias Vline = VLine
  end
end
