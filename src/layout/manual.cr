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
    # A `Widget` with no layout falls back to the shared, stateless `DEFAULT`
    # instance, keeping the render path uniform.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Manual screenshot](../../tests/layout/manual/manual.5s.apng)
    # <!-- /widget-examples:capture -->
    class Manual < Layout
      DEFAULT = new

      # Children resolve their own coordinates against the parent, so this needs
      # no interior rectangle and bypasses the base's interior gating.
      def render_children(container : Widget) : Nil
        container.children.each { |el| render_child el }
      end

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        container.children.each { |el| render_child el }
      end
    end
  end
end
