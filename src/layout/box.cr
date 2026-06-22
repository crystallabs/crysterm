require "./layout"

module Crysterm
  class Layout
    # Single-axis box layout — the shared engine behind `HBox` and `VBox`
    # (cf. Qt's `QHBoxLayout`/`QVBoxLayout`). Children are laid end-to-end along
    # the main axis (horizontal for `HBox`, vertical for `VBox`), separated by
    # `gap` cells. A child with an explicit main-axis size keeps it; children
    # without one share the leftover space equally (a simple stretch). On the
    # cross axis a child without an explicit size is stretched to fill the
    # interior.
    #
    # A child the layout sizes itself stays layout-managed across frames: it is
    # remembered in `@flex`/`@filled` so that next frame — when its width/height
    # is no longer nil — it is still recognised as ours and re-measured, rather
    # than mistaken for a fixed child. (To make such a child fixed, give it an
    # explicit size *before* it is first laid out.) Because sizes are reassigned
    # through the normal setters, which no-op when the value is unchanged, a
    # stable layout emits no `Resize`/`Move` events after the first frame.
    class Box < Layout
      enum Orientation
        Horizontal
        Vertical
      end

      getter orientation : Orientation
      property gap : Int32

      @cursor = 0
      @flex_unit = 0
      # Children this layout sizes: `@flex` share leftover main-axis space;
      # `@filled` are stretched to the interior on the cross axis. Sets (keyed
      # by widget identity — `Widget` has no custom `==`/`hash`) so the
      # per-child membership tests are O(1).
      @flex = Set(Widget).new
      @filled = Set(Widget).new

      def initialize(@orientation : Orientation = Orientation::Horizontal, @gap : Int32 = 0)
      end

      def arrange(container : Widget, interior : LPos) : Nil
        measure container, interior
        container.children.each do |el|
          place el, interior
          render_child el
        end
      end

      # Measures the available main-axis space and computes the per-child flex
      # share. Forgets managed children that have since left the tree so the
      # measurement reflects the current set.
      private def measure(container : Widget, interior : LPos) : Nil
        children = container.children
        @flex.select! { |el| children.includes? el }
        @filled.select! { |el| children.includes? el }

        main = main_extent interior
        gaps = children.size > 1 ? @gap * (children.size - 1) : 0

        fixed = 0
        flex = 0
        children.each do |el|
          if main_flex? el
            flex += 1
          else
            fixed += a_main_size el
          end
        end

        avail = main - fixed - gaps
        avail = 0 if avail < 0
        @flex_unit = flex > 0 ? avail // flex : 0
        @cursor = 0
      end

      # Positions one child along the main axis, advancing the cursor.
      private def place(el : Widget, interior : LPos) : Nil
        # Cross axis: stretch to fill when the child has no explicit cross size.
        if cross_flex? el
          set_cross_size el, cross_extent(interior)
          @filled << el # Set#<< is idempotent
        end

        # Main axis: explicit size wins; otherwise take an equal flex share.
        size =
          if main_flex? el
            set_main_size el, @flex_unit
            @flex << el # Set#<< is idempotent
            @flex_unit
          else
            a_main_size el
          end

        set_main_pos el, @cursor
        set_cross_pos el, 0
        @cursor += size + @gap
      end

      # Whether the child's main-axis size is decided by this layout (it had no
      # explicit size, or this layout has been sizing it).
      private def main_flex?(el : Widget) : Bool
        main_size(el).nil? || @flex.includes? el
      end

      # Whether the child's cross-axis size is decided (stretched) by this layout.
      private def cross_flex?(el : Widget) : Bool
        cross_size(el).nil? || @filled.includes? el
      end

      private def main_extent(interior : LPos) : Int32
        orientation.horizontal? ? interior.xl - interior.xi : interior.yl - interior.yi
      end

      private def cross_extent(interior : LPos) : Int32
        orientation.horizontal? ? interior.yl - interior.yi : interior.xl - interior.xi
      end

      private def main_size(el : Widget)
        orientation.horizontal? ? el.width : el.height
      end

      private def cross_size(el : Widget)
        orientation.horizontal? ? el.height : el.width
      end

      private def a_main_size(el : Widget) : Int32
        orientation.horizontal? ? el.awidth : el.aheight
      end

      private def set_main_size(el : Widget, v) : Nil
        orientation.horizontal? ? (el.width = v) : (el.height = v)
      end

      private def set_cross_size(el : Widget, v) : Nil
        orientation.horizontal? ? (el.height = v) : (el.width = v)
      end

      private def set_main_pos(el : Widget, v : Int32) : Nil
        orientation.horizontal? ? (el.left = v) : (el.top = v)
      end

      private def set_cross_pos(el : Widget, v : Int32) : Nil
        orientation.horizontal? ? (el.top = v) : (el.left = v)
      end
    end
  end
end
