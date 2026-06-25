require "../layout"

module Crysterm
  class Layout
    # Manual (coordinate) placement — the absence of a layout engine, mirroring
    # Qt, where a widget with no installed `layout` positions its children by
    # their own geometry. Each child resolves its own
    # `left`/`top`/`right`/`bottom`/`width`/`height` (absolute when given
    # `left`/`top`, relative to the parent's edges/size when given
    # `right`/`bottom`/percentages), and is rendered where it lands.
    #
    # This is why there is no separate `AbsoluteLayout`: Crysterm's positioning
    # already covers both absolute and relative placement. A `Widget` with no
    # layout (`#layout` is nil) falls back to the shared, stateless `DEFAULT`
    # instance here, so the render path stays uniform without pretending an
    # engine is installed.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Manual screenshot](../../examples/layout/manual/manual-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Manual < Layout
      DEFAULT = new

      # Manual placement needs no interior rectangle (children resolve their own
      # coordinates against the parent), so this overrides the base entry point
      # to render children directly without the interior gating.
      def render_children(container : Widget) : Nil
        container.children.each { |el| render_child el }
      end

      def arrange(container : Widget, interior : LPos) : Nil
        container.children.each { |el| render_child el }
      end
    end
  end
end
