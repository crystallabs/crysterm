module Crysterm
  module Mixin
    # Shared helper for the "push a computed CSS sub-style onto a child each
    # frame" idiom used by container widgets exposing Qt-style sub-controls
    # (`Widget::TabWidget`'s `::tab`/`::pane`, `Widget::GroupBox`'s `::title`,
    # `Widget::DockWidget`'s `::title`/`::close-button`/`::float-button`).
    #
    # Those sub-styles default to the widget's own `style` (see `Style#tab` etc.,
    # which return `@tab || self`), so when no matching rule cascaded, the getter
    # hands back the same `Style` object as `#style`. `#apply_substyle` detects
    # that fallback with `same?` and skips the push. Runs every frame — from a
    # `Event::PreRender` handler — because children snapshot their style when
    # built, before the cascade computes the parent's sub-styles.
    module SubStyle
      # Pushes *substyle* onto *child*'s `normal` style, unless *substyle* is this
      # widget's own `#style` (the `same?` fallback meaning "no sub-rule
      # matched"). Tolerates a nil *child* (e.g. an optional button or
      # auto-created label).
      #
      # The pushed style is a `dup`, so each child gets its own copy instead of
      # sharing the parent's single sub-`Style` object. Sharing is harmful:
      # `show`/`hide` mutate `styles.normal.visible` in place, so a `TabWidget`
      # hiding its current page would flip the shared pane's `visible` to false,
      # making the next page render blank too.
      protected def apply_substyle(child : Widget?, substyle : ::Crysterm::Style) : Nil
        return if substyle.same? style
        child.try(&.styles.normal=(substyle.dup))
      end
    end
  end
end
