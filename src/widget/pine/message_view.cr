require "../scrollable_text"

module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine message viewer: a scrollable pane showing a single
      # message's headers followed by its body. Navigate the body with the arrow
      # keys, PageUp/PageDown, and Home/End.
      #
      # ```
      # view = Widget::Pine::MessageView.new parent: window,
      #   from: "John Smith <john@example.com>",
      #   subject: "Re: Project update",
      #   date: "Sat, 20 Jun 2026 10:30:00 +0000",
      #   body: "Hi there,\n\nThanks for the update..."
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![MessageView screenshot](../../../tests/widget/pine/message_view/message_view.5s.apng)
      # <!-- /widget-examples:capture -->
      class MessageView < Widget::ScrollableText
        def initialize(
          *,
          from = "",
          to = "",
          date = "",
          subject = "",
          body = "",
          **box,
        )
          super **box, parse_tags: true, keys: true

          set_message from: from, to: to, date: date, subject: subject, body: body

          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end

        # Replaces the displayed message. Empty header fields are omitted, so the
        # same widget can show a plain text pane (e.g. Help) by passing only a
        # `body`.
        def set_message(*, from = "", to = "", date = "", subject = "", body = "")
          content = String.build do |s|
            any_header = false
            {"Date" => date, "From" => from, "To" => to, "Subject" => subject}.each do |name, value|
              next if value.empty?
              s << header(name, value) << '\n'
              any_header = true
            end
            s << '\n' if any_header
            s << body
          end
          reset_scroll
          set_content content
        end

        # Formats one header line with a bold, fixed-width field name.
        private def header(name : String, value : String) : String
          "{bold}#{"#{name}:".ljust(9)}{/bold}#{value}"
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
