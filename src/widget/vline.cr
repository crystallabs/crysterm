require "./line"

module Crysterm
  class Widget
    # Vertical line
    class VLine < Line
      @orientation = :vertical

      def initialize(**line)
        super @orientation, **line
      end
    end

    alias Vline = VLine
  end
end
