require "./box"
require "../mixin/interactive"

module Crysterm
  class Widget
    # Abstract input element — a `Box` that is interactive (focusable, accepts
    # keyboard input, scrolls with the arrow/paging keys).
    #
    # Qt has no counterpart for this base; it distributes focus/key handling
    # per widget instead. The behavior lives in `Mixin::Interactive`, so widgets
    # rooted in a different Qt base (e.g. `PlainTextEdit < AbstractScrollArea`)
    # can include it without becoming an `Input`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Input screenshot](../../tests/widget/input/input.5s.apng)
    # <!-- /widget-examples:capture -->
    class Input < Box
      include Mixin::Interactive
    end
  end
end
