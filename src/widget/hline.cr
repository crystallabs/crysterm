require "./line"

module Crysterm
  class Widget
    # Horizontal line
    class HLine < Line
      @orientation = :horizontal

      def initialize(**line)
        super @orientation, **line
      end
    end

    alias Hline = HLine
  end
end
