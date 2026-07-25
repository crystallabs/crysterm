require "../layout_flow"

module Crysterm
  class Layout
    # Wrapping flow (WPF's `WrapPanel`; Qt's flow-layout example). Lays children
    # left-to-right at their natural widths and wraps to a new row on overflow —
    # like `Masonry` but *without* the upward gravitation, so every child on a
    # row shares that row's top edge.
    #
    # Plain wrapping at a zero column pitch *is* `Flow`'s default `#place_one` /
    # `#column_width`, so this engine adds no behavior of its own.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Wrap screenshot](../../tests/layout/wrap/wrap.5s.apng)
    # <!-- /widget-examples:capture -->
    class Wrap < Flow
    end
  end
end
