require "../scrollable_text"
require "./pager"

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
      class TextView < Pager
        def initialize(
          content = "",
          **box,
        )
          super **box

          set_text content
        end

        # Replaces the displayed text and scrolls back to the top.
        def set_text(content)
          reset_and_set_content content
        end
      end
    end
  end
end
