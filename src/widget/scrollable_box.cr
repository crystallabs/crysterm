require "./abstract_scroll_area"
require "../mixin/nav_keys"

module Crysterm
  class Widget
    # A `Box` whose content can exceed its visible area and be scrolled.
    #
    # When created with `keys: true`, the arrow keys (and, with `vi_keys: true`,
    # `j`/`k`) scroll by a line, `Ctrl-U`/`Ctrl-D` by half a page,
    # `Ctrl-B`/`Ctrl-F`/`PageUp`/`PageDown` by a full page, and `g`/`Home`,
    # `G`/`End` jump to the top/bottom.
    #
    # The horizontal axis mirrors this: `Left`/`Right` (and, with `vi_keys`, `h`/`l`)
    # scroll by a column, `Ctrl-Left`/`Ctrl-Right` by a full page (one content
    # width), and `Shift-Home`/`Shift-End` (or vi_keys `0`/`$`) jump to the first/last
    # column. The scroll machinery itself lives in the base `Widget`; this only
    # wires the keys.
    #
    # <!-- widget-examples:capture v1 -->
    # ![ScrollableBox screenshot](../../tests/widget/scrollable_box/scrollable_box.5s.apng)
    # <!-- /widget-examples:capture -->
    class ScrollableBox < AbstractScrollArea
      include Mixin::NavKeys

      @scrollable = true
      # Show a real `ScrollBar` automatically when the content overflows (Qt's
      # default `AsNeeded`). Opt out with `scrollbar_policy: AlwaysOff` (or the
      # legacy `scrollbar: false`).
      @scrollbar_policy = ScrollBarPolicy::AsNeeded

      def initialize(**box)
        super **box

        if @keys
          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end
      end

      def on_keypress(e)
        visible = visible_content_rows
        half = Math.max visible // 2, 1
        # A horizontal "page" is one content width, mirroring the vertical page
        # (`visible`). Floored at 1 so a degenerate viewport still advances.
        hpage = Math.max content_width, 1

        # `NavKeys` classifies the vertical axis only; the horizontal axis stays inline.
        case nav_intent(e)
        when .backward?      then scroll -1
        when .forward?       then scroll 1
        when .half_backward? then scroll -half
        when .half_forward?  then scroll half
        when .page_backward? then scroll -visible
        when .page_forward?  then scroll visible
        when .first?         then scroll_to 0
        when .last?          then scroll_to scroll_height
        else
          case
          when e.key == ::Tput::Key::Left, (@vi_keys && e.char == 'h')
            scroll_by_x -1
          when e.key == ::Tput::Key::Right, (@vi_keys && e.char == 'l')
            scroll_by_x 1
          when e.key == ::Tput::Key::CtrlLeft
            scroll_by_x -hpage
          when e.key == ::Tput::Key::CtrlRight
            scroll_by_x hpage
          when e.key == ::Tput::Key::ShiftHome, (@vi_keys && e.char == '0')
            scroll_to_x 0
          when e.key == ::Tput::Key::ShiftEnd, (@vi_keys && e.char == '$')
            scroll_to_x scroll_width
          else
            return
          end
        end

        # Consume the handled key (don't also drive an ancestor) and repaint.
        e.accept
        request_render
      end
    end
  end
end
