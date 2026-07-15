require "../scrollable_text"

module Crysterm
  class Widget
    module Pine
      # Shared base for Pine/Alpine's scrollable text panes (`MessageView`,
      # `TextView`): navigate with arrow keys (line), PageUp/PageDown (half
      # page), Home/End (top/bottom).
      abstract class Pager < Widget::ScrollableText
        def initialize(
          **box,
        )
          super **box, parse_tags: true, keys: true

          # Deliberately does not register `on_keypress`: `super` already did, and
          # virtual dispatch reaches this override. Registering again would scroll
          # twice per key.
        end

        # Replaces the displayed content and scrolls back to the top.
        private def reset_and_set_content(content)
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
          # Consume the handled key so it doesn't also drive an ancestor.
          e.accept
          request_render
        end
      end
    end
  end
end
