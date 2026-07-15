module Crysterm
  # Spacing *inside* the element, between its border and its content.
  # Same per-side order as HTML (ltrb).
  class Padding
    include SidedGeometry

    SidedGeometry.zero_box
  end
end
