module Crysterm
  # Spacing *inside* the element, between its border and its content.
  # Same per-side order as HTML (ltrb).
  class Padding
    include SidedGeometry

    SidedGeometry.zero_box

    # The shared frozen zero box `Style#padding_view` returns for a style with
    # no padding of its own.
    ZERO = default.freeze!
  end
end
