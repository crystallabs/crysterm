require "./scrollable_box"

module Crysterm
  class Widget
    # A `ScrollableBox` in **always-scroll** mode: the viewport is addressed by
    # its top row (`#child_base`) over the whole content height, rather than by a
    # cursor row inside it, and `#scroll_percent` measures against
    # `content_height - viewport` instead of `content_height - 1`.
    #
    # That is the right model for a body of *text* that is only read and scrolled
    # (no selectable row), which is why `Log`, `Chat::Transcript` and
    # `Pine::Pager` all derive it rather than `ScrollableBox`.
    #
    # It is deliberately nothing more than that one flag: `ScrollableBox.new(…,
    # always_scroll: true)` builds exactly the same widget. The class earns its
    # keep as the *name* of that configuration — a base for the text viewers and
    # a CSS type selector (`ScrollableText { … }`) they share — not as extra
    # behavior.
    #
    # <!-- widget-examples:capture v1 -->
    # ![ScrollableText screenshot](../../tests/widget/scrollable_text/scrollable_text.5s.apng)
    # <!-- /widget-examples:capture -->
    class ScrollableText < ScrollableBox
      @always_scroll = true
    end
  end
end
