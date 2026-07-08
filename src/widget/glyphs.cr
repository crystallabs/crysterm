module Crysterm
  class Widget
    # Deprecated glyph constants, superseded by the central `Crysterm::Glyphs`
    # registry (`Glyphs::Role::LineVertical`, `::LineHorizontal`,
    # `::TreeExpanded`, `::TreeCollapsed` — resolved per support tier via
    # `Widget#glyph`). Kept only for source compatibility; being compile-time
    # constants they can't follow `Screen#glyph_tier` or `Glyphs.set`, so new
    # code should use the registry.

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
