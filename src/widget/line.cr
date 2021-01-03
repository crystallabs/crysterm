require "./node"

module Crysterm
  module Widget
    # Line element
    class Line < Box
      @type = :line

      @orientation = :vertical

      def initialize(@orientation)
        if @orientation == :vertical
          @width = 1
        else
          @height = 1
        end

        super

        @ch = (!@type || (@type==:line)) ?
          (@orientation == :horizontal ? '-' : '|') :
          (@ch || "")

        @border = {
          "type" => "bg"
        }

        # TODO
        #@style.border=@style
      end
    end
  end
end
