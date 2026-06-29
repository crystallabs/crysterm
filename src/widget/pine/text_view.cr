require "../scrollable_text"

module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine text pager: a generic scrollable pane for arbitrary
      # text, such as Alpine's HELP TEXT VIEWER or any plain read-only text
      # pane. Navigate with the arrow keys (line at a time), PageUp/PageDown
      # (half a page), and Home/End (top/bottom). Tag markup is rendered.
      #
      # Unlike `MessageView`, this widget has no email/header semantics: it just
      # shows whatever text you give it.
      #
      # ```
      # view = Widget::Pine::TextView.new parent: screen,
      #   content: "Welcome to the help viewer.\n\nUse the arrow keys to scroll."
      # view.focus
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![TextView screenshot](../../../examples/widget/pine/text_view/text_view-capture5s.apng)
      # <!-- /widget-examples:capture -->
      class TextView < Widget::ScrollableText
        def initialize(
          content = "",
          **box,
        )
          super **box, parse_tags: true, keys: true

          set_text content

          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
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
            request_render
          when ::Tput::Key::Down
            scroll 1
            request_render
          when ::Tput::Key::PageUp
            scroll -(aheight // 2)
            request_render
          when ::Tput::Key::PageDown
            scroll aheight // 2
            request_render
          when ::Tput::Key::Home
            scroll_to 0
            request_render
          when ::Tput::Key::End
            scroll_to get_scroll_height
            request_render
          end
        end
      end
    end
  end
end
