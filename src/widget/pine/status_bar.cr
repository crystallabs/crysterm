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
      # ![StatusBar screenshot](../../../tests/widget/pine/status_bar/status_bar.5s.apng)
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

          # The child needs its own `Style` copy: a shared instance would let a
          # visibility/state change on one bleed onto the other, so hiding the bar
          # would flip the child's `visible` flag and never restore it. Its
          # border/padding are stripped too: a height-1 inner box with either
          # would blank its own row the same way an unstripped ToolBox header
          # does (B18-54).
          @status = Widget::Box.new(
            height: h,
            width: "100%",
            align: :hcenter,
            style: style.stripped_frame,
            content: status_content,
          )

          append @status
        end
      end
    end
  end
end
