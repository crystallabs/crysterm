module Crysterm
  class Widget
    # A `Box` whose content can exceed its visible area and be scrolled.
    #
    # When created with `keys: true`, the arrow keys (and, with `vi: true`,
    # `j`/`k`) scroll by a line, `Ctrl-U`/`Ctrl-D` by half a page,
    # `Ctrl-B`/`Ctrl-F`/`PageUp`/`PageDown` by a full page, and `g`/`Home`,
    # `G`/`End` jump to the top/bottom. The scroll machinery itself lives in the
    # base `Widget` (`widget_scrolling.cr`); this only wires the keys.
    #
    # <!-- widget-examples:capture v1 -->
    # ![ScrollableBox screenshot](../../examples/widget/scrollable_box/scrollable_box-capture.png)
    # <!-- /widget-examples:capture -->
    class ScrollableBox < Box
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
        visible = aheight - iheight
        half = Math.max visible // 2, 1

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
        else
          return
        end

        # A key we handled: consume it (so it doesn't also drive an ancestor)
        # and repaint.
        e.accept
        request_render
      end
    end
  end
end
