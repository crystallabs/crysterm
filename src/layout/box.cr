require "../layout"

module Crysterm
  class Layout
    # Single-axis box layout — the shared engine behind `HBox` and `VBox`
    # (cf. Qt's `QHBoxLayout`/`QVBoxLayout`), with CSS-flexbox-style sizing.
    # Children are laid end-to-end along the main axis (horizontal for `HBox`,
    # vertical for `VBox`), separated by `gap` cells.
    #
    # * **Main axis:** a child with an explicit main-axis size keeps it; the rest
    #   share the leftover space in proportion to their `grow` factor (default
    #   1 — i.e. equal shares, matching the original behavior). Set a per-child
    #   factor with `layout_hint: Layout::Box::Hint.new(grow: 2)`.
    # * **`justify`** distributes leftover space along the main axis *when there
    #   are no growing children* (Start/Center/End/SpaceBetween/SpaceAround).
    # * **`align`** sets cross-axis placement: `Stretch` (default) fills the
    #   cross axis for children without an explicit cross size; `Start`/`Center`/
    #   `End` keep the child's own cross size and position it.
    #
    # Sizes this layout assigns are remembered (`@flex`/`@filled`) so a child it
    # sized is still recognised as managed next frame, and reassigned through the
    # normal setters (which no-op when unchanged) so a stable layout emits no
    # events after the first frame.
    class Box < Layout
      enum Orientation
        Horizontal
        Vertical
      end

      enum Justify
        Start
        Center
        End
        SpaceBetween
        SpaceAround
      end

      enum Align
        Stretch
        Start
        Center
        End
      end

      # Per-child main-axis grow factor (proportional share of leftover space).
      class Hint < Layout::Hint
        getter grow : Int32

        def initialize(@grow : Int32 = 1)
        end
      end

      getter orientation : Orientation
      # `#gap` (inter-child spacing) is inherited from `Layout`.
      property justify : Justify
      property align : Align

      @cursor = 0
      @avail = 0
      @total_grow = 0
      @extra_gap = 0
      @flex = Set(Widget).new
      @filled = Set(Widget).new
      # Per-arrange cache of fixed children's resolved main-axis size, so the
      # `a_main_size` (an `awidth`/`aheight` ancestor-chain walk) computed in
      # `measure` is reused by `place` instead of walked a second time. Repopulated
      # every `measure`; a child's main size is stable between the two passes (the
      # only mutation in between is its cross-axis size, which the main axis does
      # not depend on).
      @measured = {} of Widget => Int32

      def initialize(
        @orientation : Orientation = Orientation::Horizontal,
        @gap : Int32 = 0,
        @justify : Justify = Justify::Start,
        @align : Align = Align::Stretch,
      )
      end

      def arrange(container : Widget, interior : LPos) : Nil
        measure container, interior
        container.children.each do |el|
          next if el.layout_excluded?
          place el, interior
          render_child el
        end
      end

      # Measures the main axis: total fixed size, total grow weight, the leftover
      # to distribute, and (when nothing grows) the `justify` lead/extra-gap.
      private def measure(container : Widget, interior : LPos) : Nil
        children = container.children
        @flex.select! { |el| children.includes? el }
        @filled.select! { |el| children.includes? el }

        main = main_extent interior
        # Count only the children this engine actually arranges; layout-excluded
        # chrome (e.g. a `background-image` layer, a scrollbar) must not consume a
        # gap or a `justify` slot.
        n = children.count { |el| !el.layout_excluded? }
        gaps = n > 1 ? @gap * (n - 1) : 0

        fixed = 0
        grow = 0
        @measured.clear
        children.each do |el|
          next if el.layout_excluded?
          if main_flex? el
            grow += grow_of el
          else
            ms = a_main_size el
            @measured[el] = ms
            fixed += ms
          end
        end

        @total_grow = grow
        @avail = main - fixed - gaps
        @avail = 0 if @avail < 0

        lead = 0
        @extra_gap = 0
        if grow == 0
          leftover = @avail
          case @justify
          when .center?        then lead = leftover // 2
          when .end?           then lead = leftover
          when .space_between? then @extra_gap = n > 1 ? leftover // (n - 1) : 0
          when .space_around?
            lead = n > 0 ? leftover // (2 * n) : 0
            @extra_gap = n > 0 ? leftover // n : 0
          end
        end
        @cursor = lead
      end

      private def place(el : Widget, interior : LPos) : Nil
        # Cross axis.
        cross = cross_extent interior
        if @align.stretch?
          if cross_flex? el
            set_cross_size el, cross
            @filled << el
          end
          set_cross_pos el, 0
        else
          cs = a_cross_size el
          off = case @align
                when .center? then (cross - cs) // 2
                when .end?    then cross - cs
                else               0
                end
          set_cross_pos el, (off < 0 ? 0 : off)
        end

        # Main axis: explicit size wins; otherwise a grow-weighted share.
        size =
          if main_flex? el
            s = @total_grow > 0 ? (@avail * grow_of(el)) // @total_grow : 0
            set_main_size el, s
            @flex << el
            s
          else
            # Reuse the size measured for this fixed child in `measure`.
            @measured[el]? || a_main_size el
          end

        set_main_pos el, @cursor
        @cursor += size + @gap + @extra_gap
      end

      private def grow_of(el : Widget) : Int32
        (el.layout_hint.as?(Hint)).try(&.grow) || 1
      end

      # Whether the child's main-axis size is decided by this layout.
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

      private def a_cross_size(el : Widget) : Int32
        orientation.horizontal? ? el.aheight : el.awidth
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
