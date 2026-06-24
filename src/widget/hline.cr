require "./line"

module Crysterm
  class Widget
    # Horizontal line
    #
    # <!-- widget-examples:capture v1 -->
    # ![HLine screenshot](../../examples/widget/hline/hline-capture.png)
    # <!-- /widget-examples:capture -->
    class HLine < Line
      @orientation = :horizontal

      def initialize(**line)
        super @orientation, **line
      end
    end

    # <!-- widget-examples:capture v1 -->
    # ![HLine screenshot](../../examples/widget/hline/hline-capture.png)
    # <!-- /widget-examples:capture -->
    alias Hline = HLine
  end
end
