module Crysterm
  # Class for margin definition.
  #
  # Margin is spacing *outside* the element — the mirror of `Padding`, and
  # outward like CSS. Where `Padding`/`Border` are inner insets that shrink the
  # content area (via `Widget#ileft` & co.), a margin keeps the element's own
  # size and pushes it away from its anchored edge, reserving empty space around
  # it (a fixed-size box shifts; an auto/stretched box shrinks by its margins,
  # as in CSS). Inner content offsets are untouched. Same per-side order as
  # HTML (ltrb).
  class Margin
    include SidedGeometry

    # The four per-side properties, `.default`, `.from` and the integer
    # constructors are generated identically for `Margin` and `Padding`.
    SidedGeometry.zero_box

    # Per-side predicates, `any?` and `adjust` come from `SidedGeometry`.
  end
end
