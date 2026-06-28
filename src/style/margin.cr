module Crysterm
  # Class for margin definition.
  #
  # NOTE "Margin" as in spacing *outside* the element — the mirror of `Padding`.
  # Where `Padding`/`Border` are inner insets (they shrink the *content* area and
  # push children inward, via `Widget#ileft` & co.), a margin is the element's own
  # *outer* spacing: it shifts the element inward from its computed position and
  # shrinks it within its allotted slot, without affecting the inner content
  # offsets. Same per-side order as in HTML (ltrb).
  class Margin
    include SidedGeometry

    # The four per-side properties, `.default`, `.from` and the integer
    # constructors are generated identically for `Margin` and `Padding`.
    SidedGeometry.zero_box

    # Per-side predicates, `any?` and `adjust` come from `SidedGeometry`.
  end
end
