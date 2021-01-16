require "./node"

module Crysterm
  module Widget
    # Line element
    class Line < Box
      @orientation = :vertical

      def initialize(@orientation)
        if @orientation == :vertical
          @width = 1
        else
          @height = 1
        end

        super

        @ch = (is_a? Line) ? (@orientation == :horizontal ? '-' : '|') : (@ch || "")

        @border = {
          "type" => "bg",
        }

        # TODO
        # @style.border=@style
      end
    end
  end
end
