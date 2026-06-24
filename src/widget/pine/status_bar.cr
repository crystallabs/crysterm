module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine status / message line, shown just above the bottom
      # `KeyMenu`. Messages (e.g. `[Folder "INBOX" opened with 5 messages]`) are
      # displayed horizontally centered, matching Alpine.
      #
      # Update the text at runtime via `status_bar.status.content = "..."`.
      #
      # <!-- widget-examples:capture v1 -->
      # ![StatusBar screenshot](../../../examples/widget/pine/status_bar/status_bar-capture5s.apng)
      # <!-- /widget-examples:capture -->
      class StatusBar < Widget::Box
        getter status : Widget::Box

        def initialize(
          height h = 1, width w = "100%",
          status_content = "",
          style = Style.new,
          **layout,
        )
          super **layout, style: style, width: w, height: h

          @status = Widget::Box.new(
            height: h,
            width: "100%",
            align: :hcenter,
            style: style,
            content: status_content,
          )

          append @status
        end
      end
    end
  end
end
