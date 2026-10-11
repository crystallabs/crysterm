module Crysterm
  # Spacing *outside* the element. Unlike `Padding`/`Border`, which are inner
  # insets that shrink the content area, a margin leaves inner content offsets
  # untouched and pushes the element away from its anchored edge: a fixed-size
  # box shifts, an auto/stretched box shrinks by its margins, as in CSS.
  # Same per-side order as HTML (ltrb).
  class Margin
    include SidedGeometry

    SidedGeometry.zero_box

    # The shared frozen zero box `Style#margin_view` returns for a style with
    # no margin of its own.
    ZERO = default.freeze!
  end
end
