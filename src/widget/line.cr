module Crysterm
  class Widget
    # Line element
    class Line < Box
      @orientation = Tput::Orientation::Vertical

      def initialize(orientation = nil, **box)
        orientation.try { |v| @orientation = v }

        # if @orientation == Tput::Orientation::Vertical
        #  @width = 1
        # else
        #  @height = 1
        # end

        super **box

        # TODO possibly replace -/| with ACS chars?
        style.char = (is_a? Line) ? (@orientation == :horizontal ? '-' : '|') : style.char

        @border = Border.new type: BorderType::Bg

        # TODO
        # style.border=style
      end
    end
  end
end
