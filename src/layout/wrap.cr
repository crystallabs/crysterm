require "./flow"

module Crysterm
  class Layout
    # Wrapping flow (WPF's `WrapPanel`; Qt's flow-layout example). Lays children
    # left-to-right at their natural widths and wraps to a new row on overflow —
    # like `Masonry` but *without* the upward gravitation, so every child on a
    # row shares that row's top edge. Good for tag clouds, button bars and
    # toolbars that should reflow.
    class Wrap < Flow
      protected def place_one(container : Widget, el : Widget, i : Int32, interior : LPos) : Overflow?
        flow_place container, el, i, interior, 0
        overflow_action container, el, interior
      end
    end
  end
end
