require "./line"

module Crysterm
  class Widget
    # Vertical line
    #
    # <!-- widget-examples:capture v1 -->
    # ![VLine screenshot](../../tests/widget/vline/vline.5s.apng)
    # <!-- /widget-examples:capture -->
    class VLine < Line
      @orientation = :vertical

      def initialize(**line)
        super @orientation, **line
      end
    end
  end
end
