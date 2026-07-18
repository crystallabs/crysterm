require "../layout"

module Crysterm
  class Layout
    # Stacked layout (Qt's `QStackedLayout`, Swing's `CardLayout`). All children
    # occupy the same area at the top-left of the interior; only the child at
    # `#current_index` is rendered, the rest are suppressed. Backbone of tabbed
    # panes, wizards and view-switchers.
    #
    # Children keep their own size: one without explicit `width`/`height` fills
    # the interior (Crysterm's default sizing); one with an explicit size is
    # shown at that size in the top-left. Set a different page with `#current_index = i`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Stack screenshot](../../tests/layout/stack/stack.5s.apng)
    # <!-- /widget-examples:capture -->
    class Stack < Layout
      # Index of the child to show. Clamped to the available children at render.
      # Change-guarded so switching pages repaints the container.
      @current_index : Int32

      # :ditto:
      def current_index : Int32
        @current_index
      end

      # :ditto:
      def current_index=(value : Int32) : Int32
        return value if value == @current_index
        @current_index = value
        invalidate
        value
      end

      def initialize(@current_index : Int32 = 0)
      end

      # Number of pages — the arrangeable children `#arrange` addresses by
      # `#current_index` (layout-excluded chrome doesn't count). Zero when the
      # layout isn't installed on a container.
      def count : Int32
        c = container
        c ? arrangeable_count(c) : 0
      end

      # The page currently shown — the child at `#current_index`, clamped exactly
      # as `#arrange` clamps it. Nil when there are no pages / no container.
      def current_widget : Widget?
        n = count
        return nil if n == 0
        widget current_index.clamp(0, n - 1)
      end

      # The page (arrangeable child) at *index* in page order, or nil when out of
      # range or not installed on a container.
      def widget(index : Int32) : Widget?
        c = container
        return nil if c.nil? || index < 0
        i = 0
        each_arrangeable(c) do |el|
          return el if i == index
          i += 1
        end
        nil
      end

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        # `#current_index` indexes the *pages* this engine arranges, not the raw
        # child array: layout-excluded chrome must not occupy a page slot, or page
        # indices shift.
        n = arrangeable_count container
        return if n == 0
        shown = current_index.clamp(0, n - 1)

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
