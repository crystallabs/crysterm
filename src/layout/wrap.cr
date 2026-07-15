require "../layout_flow"

module Crysterm
  class Layout
    # Wrapping flow (WPF's `WrapPanel`; Qt's flow-layout example). Lays children
    # left-to-right at their natural widths and wraps to a new row on overflow —
    # like `Masonry` but *without* the upward gravitation, so every child on a
    # row shares that row's top edge.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Wrap screenshot](../../tests/layout/wrap/wrap.5s.apng)
    # <!-- /widget-examples:capture -->
    class Wrap < Flow
      protected def place_one(container : Widget, el : Widget, i : Int32, interior : RenderedGeometry) : Overflow?
        flow_place container, el, i, interior, 0
        overflow_action container, el, interior
      end
    end
  end
end
