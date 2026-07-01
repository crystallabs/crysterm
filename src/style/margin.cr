module Crysterm
  # Class for margin definition.
  #
  # Margin is spacing *outside* the element — the mirror of `Padding`. Where
  # `Padding`/`Border` are inner insets that shrink the content area (via
  # `Widget#ileft` & co.), a margin shifts the element inward from its computed
  # position and shrinks it within its allotted slot, without affecting inner
  # content offsets. Same per-side order as HTML (ltrb).
  class Margin
    include SidedGeometry

    # The four per-side properties, `.default`, `.from` and the integer
    # constructors are generated identically for `Margin` and `Padding`.
    SidedGeometry.zero_box

    # Per-side predicates, `any?` and `adjust` come from `SidedGeometry`.
  end
end
