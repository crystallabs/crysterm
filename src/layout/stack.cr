require "../layout"

module Crysterm
  class Layout
    # Stacked layout (Qt's `QStackedLayout`, Swing's `CardLayout`). All children
    # occupy the same area at the top-left of the interior; only the child at
    # `#current` is rendered, the rest are suppressed. Backbone of tabbed
    # panes, wizards and view-switchers.
    #
    # Children keep their own size: one without explicit `width`/`height` fills
    # the interior (Crysterm's default sizing); one with an explicit size is
    # shown at that size in the top-left. Set a different page with `#current = i`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Stack screenshot](../../tests/layout/stack/stack.5s.apng)
    # <!-- /widget-examples:capture -->
    class Stack < Layout
      # Index of the child to show. Clamped to the available children at render.
      property current : Int32

      def initialize(@current : Int32 = 0)
      end

      def arrange(container : Widget, interior : LPos) : Nil
        # `#current` indexes the *pages* this engine arranges, not the raw child
        # array: layout-excluded chrome (rendered out-of-band; see
        # `#each_arrangeable`) must not occupy a page slot, or page indices shift
        # (or `#current` lands on an excluded child and nothing renders).
        n = arrangeable_count container
        return if n == 0
        shown = current.clamp(0, n - 1)

        visible = 0
        each_arrangeable container do |el|
          # Every arrangeable child gets an index slot (z-order bookkeeping).
          bump_index el
          if visible == shown
            el.left = 0
            el.top = 0
            render_or_defer el
          else
            skip_subtree el
          end
          visible += 1
        end
      end
    end
  end
end
