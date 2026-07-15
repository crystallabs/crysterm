module Crysterm
  class Widget
    # Deprecated glyph constants, superseded by the `Crysterm::Glyphs` registry
    # (resolved per support tier via `Widget#glyph`). Being compile-time
    # constants they can't follow `Screen#glyph_tier` or `Glyphs.set`.

    @[Deprecated("Use `glyph(Glyphs::Role::LineVertical)` (tier-aware) instead")]
    LINE_VERTICAL = '│'

    @[Deprecated("Use `glyph(Glyphs::Role::LineHorizontal)` (tier-aware) instead")]
    LINE_HORIZONTAL = '─'

    @[Deprecated("Use `glyph(Glyphs::Role::TreeExpanded)` (tier-aware) instead")]
    MARKER_EXPANDED = '▾'

    @[Deprecated("Use `glyph(Glyphs::Role::TreeCollapsed)` (tier-aware) instead")]
    MARKER_COLLAPSED = '▸'
  end
end
