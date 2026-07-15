module Crysterm
  class Widget
    # Identity of the sub-`Style` object last pushed onto this widget by an
    # ancestor's `Mixin::SubStyle#apply_substyle`, letting that per-frame push
    # skip re-`dup`ing an unchanged sub-style. The cascade *replaces* sub-`Style`
    # objects on recompute rather than mutating them in place, so a `same?` hit
    # means the pushed copy is still current.
    property _substyle_src : ::Crysterm::Style? = nil
  end

  module Mixin
    # Shared helper for the "push a computed CSS sub-style onto a child each
    # frame" idiom used by container widgets exposing Qt-style sub-controls.
    #
    # Must run every frame, from a `Event::PreRender` handler: children snapshot
    # their style when built, before the cascade computes the parent's
    # sub-styles.
    module SubStyle
      # Pushes *substyle* onto *child*'s `normal` style, unless *substyle* is this
      # widget's own `#style` — a sub-style getter falls back to `self` when no
      # sub-rule matched, and `same?` detects that. Tolerates a nil *child*.
      #
      # The pushed style is a `dup`: sharing the parent's single sub-`Style`
      # object across children is harmful, since `show`/`hide` mutate
      # `styles.normal.visible` in place, so hiding one child would render its
      # siblings blank too.
      #
      # The `dup` is memoized per child (`Widget#_substyle_src`) — in steady
      # state the cascade hands back the same object frame after frame, so a
      # `same?` hit reduces this to a bare identity compare.
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
