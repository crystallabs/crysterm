require "../scrollable_text"

module Crysterm
  class Widget
    module Pine
      # Pine/Alpine text pager: a generic scrollable pane for arbitrary text
      # (e.g. Alpine's HELP TEXT VIEWER). Navigate with arrow keys (line),
      # PageUp/PageDown (half page), Home/End (top/bottom). Tag markup rendered.
      #
      # Unlike `MessageView`, this widget has no email/header semantics.
      #
      # ```
      # view = Widget::Pine::TextView.new parent: screen,
      #   content: "Welcome to the help viewer.\n\nUse the arrow keys to scroll."
      # view.focus
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![TextView screenshot](../../../tests/widget/pine/text_view/text_view.5s.apng)
      # <!-- /widget-examples:capture -->
      class TextView < Widget::ScrollableText
        def initialize(
          content = "",
          **box,
        )
          super **box, parse_tags: true, keys: true

          set_text content

          # `ScrollableBox#initialize` already registered `on_keypress` (via
          # virtual dispatch it reaches this override). Registering it again here
          # would fire the handler twice per key — scrolling double.
        end

        # Replaces the displayed text and scrolls back to the top.
        def set_text(content)
          reset_scroll
          set_content content
        end

        def on_keypress(e)
          case e.key
          when ::Tput::Key::Up
            scroll -1
          when ::Tput::Key::Down
            scroll 1
          when ::Tput::Key::PageUp
            scroll -(aheight // 2)
          when ::Tput::Key::PageDown
            scroll aheight // 2
          when ::Tput::Key::Home
            scroll_to 0
          when ::Tput::Key::End
            scroll_to get_scroll_height
          else
            return
          end
          # Consume the handled key so it doesn't also drive an ancestor, and
          # repaint (mirrors the base `ScrollableBox#on_keypress`).
          e.accept
          request_render
        end
      end
    end
  end
end
