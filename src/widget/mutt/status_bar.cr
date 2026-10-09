require "../box"

module Crysterm
  class Widget
    module Mutt
      # Mutt's **status line**: a reverse-video bar whose left zone shows the
      # current context (mailbox, message counts, sort order) and whose right
      # zone shows a trailing indicator (thread mode, scroll percentage), with
      # the gap between them filled by dashes:
      #
      # ```
      # -*-Mutt: INBOX [Msgs:8 New:3]------------------------(threads/date)-(all)---
      # ```
      #
      # The dashes are just the box's `fill_char`, so the widget is a plain `Box`
      # with a right-docked child for the right zone — no per-frame width
      # arithmetic. It serves both Mutt's index and pager status lines; only the
      # text differs.
      # Excluded from the DOM-loader registry: self-populating composite
      # (see `Crysterm::DOM::Skip`).
      @[::Crysterm::DOM::Skip]
      class StatusBar < Widget::Box
        # The right-aligned zone (e.g. `-(threads/date)-(all)-`).
        getter right_zone : Widget::Box

        def initialize(
          left : String = "",
          right : String = "",
          height h = 1,
          width w = "100%",
          **opts,
        )
          super **opts, width: w, height: h,
            style: Style.new(reverse: true, fill_char: '-'),
            content: left

          # Docks the right zone against the far edge, as wide as its text, so
          # the left zone keeps every column the right one does not need; its
          # dash fill continues the parent's, so the bar reads as one dashed
          # line at any width.
          @layout = Crysterm::Layout::Dock.new

          @right_zone = Widget::Box.new(
            height: h,
            width: zone_width(right),
            align: {:vcenter, :right},
            style: Style.new(reverse: true, fill_char: '-'),
            content: right,
            layout_hint: Crysterm::Layout::Dock::Hint.new(:right),
          )
          append @right_zone
        end

        # Replaces the left and right zone text.
        def set_text(left : String, right : String = "")
          self.content = left
          @right_zone.content = right
          @right_zone.width = zone_width(right)
        end

        # The right zone's width: its text, at least one dash wide.
        private def zone_width(text : String) : Int32
          Math.max(1, str_width(text))
        end
      end
    end
  end
end
