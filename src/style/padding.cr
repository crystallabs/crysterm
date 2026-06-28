module Crysterm
  # Class for padding definition.
  #
  # NOTE "Padding" as in spacing around elements. Same order as in HTML (ltrb)
  class Padding
    include SidedGeometry

    # The four per-side properties, `.default`, `.from` and the integer
    # constructors are generated identically for `Padding` and `Margin`.
    SidedGeometry.zero_box

    # Per-side predicates, `any?` and `adjust` come from `SidedGeometry`.
  end
end
