module Crysterm
  class Widget
    # Identity of the sub-`Style` object last pushed onto this widget by an
    # ancestor's `Mixin::SubStyle#apply_substyle`. Lets that per-frame push skip
    # re-`dup`ing when the cascade-computed sub-style hasn't changed since the
    # last frame — the cascade *replaces* sub-`Style` objects on recompute
    # (never mutates them in place), so a `same?` hit means the pushed copy is
    # still current. Nil until the first push; lives and dies with the child, so
    # no separate cleanup is needed. See `Mixin::SubStyle#apply_substyle`.
    property _substyle_src : ::Crysterm::Style? = nil
  end

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
      #
      # Memoized per child (`Widget#_substyle_src`): this runs every frame from a
      # `Event::PreRender` handler, but the source *substyle* is the same
      # cascade-computed object frame after frame in steady state. Recording the
      # last-pushed source and skipping on a `same?` hit turns the common case
      # from a ~5-object `Style#dup` per sub-styled child per frame into a bare
      # identity compare; the `dup` runs only when the cascade hands back a new
      # sub-`Style` object.
      protected def apply_substyle(child : Widget?, substyle : ::Crysterm::Style) : Nil
        return if substyle.same? style
        return unless child
        return if (src = child._substyle_src) && src.same?(substyle)
        child.styles.normal = substyle.dup
        child._substyle_src = substyle
      end
    end
  end
end
