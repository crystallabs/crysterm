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
      # The dashes are just the box's `fill_char`, so the widget is a plain
      # `Box` with a right-docked child for the right zone — no per-frame width
      # arithmetic. The same widget serves Mutt's index status line and its
      # pager status line; only the text differs. Set both zones with `#set`.
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

          # A `Border` layout docks the right zone against the far edge; its own
          # dash fill continues seamlessly from the parent's, so the whole bar
          # reads as one dashed line regardless of terminal width.
          @layout = Crysterm::Layout::Border.new

          @right_zone = Widget::Box.new(
            height: h,
            width: "60%",
            align: {:vcenter, :right},
            style: Style.new(reverse: true, fill_char: '-'),
            content: right,
            layout_hint: Crysterm::Layout::Border::Hint.new(:right),
          )
          append @right_zone
        end

        # Replaces the left and right zone text.
        def set(left : String, right : String = "")
          self.content = left
          @right_zone.content = right
        end
      end
    end
  end
end
