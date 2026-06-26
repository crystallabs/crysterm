module Crysterm
  module Mixin
    # Shared helper for the "push a computed CSS sub-style onto a child each
    # frame" idiom used by the container widgets that expose Qt-style sub-controls
    # (`Widget::TabWidget`'s `::tab`/`::pane`, `Widget::GroupBox`'s `::title`,
    # `Widget::DockWidget`'s `::title`/`::close-button`/`::float-button`).
    #
    # Those sub-styles default to the widget's own `style` (see `Style#tab` etc.,
    # which return `@tab || self`), so when no matching rule cascaded, the getter
    # hands back the very same `Style` object as `#style`. `#apply_substyle`
    # detects that fallback with `same?` and skips the push, leaving the child its
    # existing (themed/default) look. The push runs every frame — from a
    # `Event::PreRender` handler — because children snapshot their style when first
    # built, before the cascade has computed the parent's sub-styles.
    module SubStyle
      # Pushes *substyle* onto *child*'s `normal` style, unless *substyle* is this
      # widget's own `#style` (the `same?` fallback meaning "no sub-rule matched"),
      # in which case it is a no-op. Tolerates a nil *child* (e.g. an optional
      # button or auto-created label).
      #
      # The pushed style is a **`dup`**, so each child gets its own copy instead of
      # sharing the parent's single sub-`Style` object. Sharing is actively
      # harmful: `show`/`hide` mutate `styles.normal.visible` in place, so a
      # `TabWidget` hiding the previously-current page would flip the shared pane
      # object's `visible` to false — and the next page handed that same object
      # (or the same page next frame) would then render blank. A per-child copy
      # keeps each child's in-place style edits to itself.
      protected def apply_substyle(child : Widget?, substyle : ::Crysterm::Style) : Nil
        return if substyle.same? style
        child.try { |c| c.styles.normal = substyle.dup }
      end
    end
  end
end
