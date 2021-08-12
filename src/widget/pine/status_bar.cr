module Crysterm
  class Widget
    module Pine
      class StatusBar < Widget::Box
        property status

        def initialize(
          height h = 1, width w = "100%",
          status_content = "",
          status : Widget? = nil,
          style = Style.new,
          **layout
        )
          super **layout, style: style, width: w, height: h

          style2 = style.dup
          style2.inverse = true

          @status = Widget::Box.new height: h, left: "center", style: style2, content: status_content

          append @status
        end
      end
    end
  end
end
