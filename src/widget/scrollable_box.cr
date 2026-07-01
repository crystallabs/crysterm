require "./abstract_scroll_area"

module Crysterm
  class Widget
    # A `Box` whose content can exceed its visible area and be scrolled.
    #
    # When created with `keys: true`, the arrow keys (and, with `vi: true`,
    # `j`/`k`) scroll by a line, `Ctrl-U`/`Ctrl-D` by half a page,
    # `Ctrl-B`/`Ctrl-F`/`PageUp`/`PageDown` by a full page, and `g`/`Home`,
    # `G`/`End` jump to the top/bottom.
    #
    # The horizontal axis mirrors this: `Left`/`Right` (and, with `vi`, `h`/`l`)
    # scroll by a column, `Ctrl-Left`/`Ctrl-Right` by a full page (one content
    # width), and `Shift-Home`/`Shift-End` (or vi `0`/`$`) jump to the first/last
    # column. The scroll machinery itself lives in the base `Widget`
    # (`widget_scrolling.cr`); this only wires the keys.
    #
    # <!-- widget-examples:capture v1 -->
    # ![ScrollableBox screenshot](../../tests/widget/scrollable_box/scrollable_box.5s.apng)
    # <!-- /widget-examples:capture -->
    class ScrollableBox < AbstractScrollArea
      @scrollable = true
      # Show a real `ScrollBar` automatically when the content overflows (Qt's
      # default `AsNeeded`). Inherited by `ScrollableText`/`Log`. Opt out with
      # `scrollbar_policy: AlwaysOff` (or the legacy `scrollbar: false`).
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

        case
        when e.key == ::Tput::Key::Up, (@vi && e.char == 'k')
          scroll -1
        when e.key == ::Tput::Key::Down, (@vi && e.char == 'j')
          scroll 1
        when e.key == ::Tput::Key::CtrlU
          scroll -half
        when e.key == ::Tput::Key::CtrlD
          scroll half
        when e.key == ::Tput::Key::PageUp, e.key == ::Tput::Key::CtrlB
          scroll -visible
        when e.key == ::Tput::Key::PageDown, e.key == ::Tput::Key::CtrlF
          scroll visible
        when e.key == ::Tput::Key::Home, (@vi && e.char == 'g')
          scroll_to 0
        when e.key == ::Tput::Key::End, (@vi && e.char == 'G')
          scroll_to get_scroll_height
        when e.key == ::Tput::Key::Left, (@vi && e.char == 'h')
          scroll_x -1
        when e.key == ::Tput::Key::Right, (@vi && e.char == 'l')
          scroll_x 1
        when e.key == ::Tput::Key::CtrlLeft
          scroll_x -hpage
        when e.key == ::Tput::Key::CtrlRight
          scroll_x hpage
        when e.key == ::Tput::Key::ShiftHome, (@vi && e.char == '0')
          scroll_x_to 0
        when e.key == ::Tput::Key::ShiftEnd, (@vi && e.char == '$')
          scroll_x_to get_scroll_width
        else
          return
        end

        # Consume the handled key (don't also drive an ancestor) and repaint.
        e.accept
        request_render
      end
    end
  end
end
