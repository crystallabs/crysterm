require "../scrollable_text"

module Crysterm
  class Widget
    module Pine
      # Shared base for Pine/Alpine's scrollable text panes (`MessageView`,
      # `TextView`). Scrolling keys come straight from `ScrollableText`
      # (arrows by a line, `Ctrl-U`/`Ctrl-D` half page, `PageUp`/`PageDown`
      # full page, `Home`/`End` top/bottom, plus the horizontal set).
      abstract class Pager < Widget::ScrollableText
        def initialize(
          **box,
        )
          super **box, parse_tags: true, keys: true
        end

        # Replaces the displayed content and scrolls back to the top.
        private def reset_and_set_content(content)
          reset_scroll
          set_content content
        end
      end
    end
  end
end
