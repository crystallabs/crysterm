require "../layout"

module Crysterm
  class Layout
    # Stacked layout (Qt's `QStackedLayout`, Swing's `CardLayout`). All children
    # occupy the same area at the top-left of the interior; only the child at
    # `#current` is rendered, the rest are suppressed. The backbone of tabbed
    # panes, wizards and view-switchers.
    #
    # Children keep their own size: one without an explicit `width`/`height`
    # fills the interior (Crysterm's default sizing), one with an explicit size
    # is shown at that size in the top-left. Set a different page with
    # `#current = i`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Stack screenshot](../../examples/layout/stack/stack-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Stack < Layout
      # Index of the child to show. Clamped to the available children at render.
      property current : Int32

      def initialize(@current : Int32 = 0)
      end

      def arrange(container : Widget, interior : LPos) : Nil
        children = container.children
        return if children.empty?
        shown = current.clamp(0, children.size - 1)

        children.each_with_index do |el, i|
          # Every child gets an index slot (z-order bookkeeping) regardless.
          bump_index el
          if i == shown
            el.left = 0
            el.top = 0
            el.render
          else
            skip el
          end
        end
      end
    end
  end
end
