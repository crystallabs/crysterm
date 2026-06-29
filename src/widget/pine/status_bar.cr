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

          # Give the child its own `Style` copy rather than sharing the bar's
          # instance: a shared `Style` means a visibility (or any state) change on
          # one bleeds onto the other. Hiding/showing the whole bar (e.g. a Pine
          # status-line yes/no prompt overlaying it, then restoring it) would
          # otherwise also flip this child's `visible` flag and never restore it —
          # the status text and themed background would not come back. Mirrors
          # `Widget::ToolBox`, which dups its child styles for the same reason.
          @status = Widget::Box.new(
            height: h,
            width: "100%",
            align: :hcenter,
            style: style.dup,
            content: status_content,
          )

          append @status
        end
      end
    end
  end
end
