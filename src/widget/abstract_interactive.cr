require "./box"
require "../mixin/interactive"

module Crysterm
  class Widget
    # Interactive base element — a `Box` that is interactive (focusable, accepts
    # keyboard input, scrolls with the arrow/paging keys).
    #
    # Qt has no counterpart for this base; it distributes focus/key handling
    # per widget instead. The behavior lives in `Mixin::Interactive`, so widgets
    # rooted in a different Qt base (e.g. `PlainTextEdit < AbstractScrollArea`)
    # can include it without becoming an `AbstractInteractive`.
    #
    # NOTE Named `Abstract*` like every other intermediate base in the tree, but
    # deliberately *not* `abstract`: a bare interactive box is a useful thing to
    # construct directly (a focusable scrollable pane with no other behavior).
    #
    # <!-- widget-examples:capture v1 -->
    # ![AbstractInteractive screenshot](../../tests/widget/abstract_interactive/abstract_interactive.5s.apng)
    # <!-- /widget-examples:capture -->
    class AbstractInteractive < Box
      include Mixin::Interactive
    end
  end
end
