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
    #   1, i.e. equal shares). Set a per-child factor with
    #   `layout_hint: Layout::Box::Hint.new(grow: 2)`.
    # * **`justify`** distributes leftover space along the main axis when no
    #   children grow (Start/Center/End/SpaceBetween/SpaceAround).
    # * **`align`** sets cross-axis placement: `Stretch` (default) fills the
    #   cross axis for children without an explicit cross size; `Start`/`Center`/
    #   `End` keep the child's own cross size and position it.
    #
    # Assigned sizes are remembered (`@flex`/`@filled`) so a sized child stays
    # recognised as managed, and reassigned through the normal setters (no-op
    # when unchanged) so a stable layout emits no events after the first frame.
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
      # Running sum of grow factors of flex children placed so far; used to
      # distribute @avail by cumulative rounding (see #place). Reset each
      # #measure, consumed in #place order.
      @grow_seen = 0
      # Leftover space distributed along the main axis by `justify` when nothing
      # grows. Carved into per-child gaps by *cumulative* rounding (see `#place`
      # and `#justify_before`) rather than a floored `leftover // slots`, which
      # drops up to `slots - 1` columns (last child of `SpaceBetween` falls short
      # of the far edge, `SpaceAround` comes out lopsided) — same fix Grid/Form
      # use. `@just_n` is the arranged-child count, `@just_k` the placement ordinal.
      @just_leftover = 0
      @just_n = 0
      @just_around = false
      @just_k = 0
      @flex = Set(Widget).new
      @filled = Set(Widget).new
      # Per-arrange cache of fixed children's resolved main-axis size, so
      # `a_main_size` (an ancestor-chain walk) computed in `measure` isn't walked
      # again in `place`. Repopulated every `measure`; stable between passes since
      # only cross-axis size changes in between.
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
        each_arrangeable container do |el|
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
        # Only children this engine actually arranges (see `#each_arrangeable`)
        # count: layout-excluded chrome must not consume a gap or justify slot.
        n = arrangeable_count container
        gaps = n > 1 ? @gap * (n - 1) : 0

        fixed = 0
        grow = 0
        @measured.clear
        each_arrangeable container do |el|
          if main_flex? el
            grow += grow_of el
          else
            ms = a_main_size el
            @measured[el] = ms
            fixed += ms
          end
        end

        @total_grow = grow
        @grow_seen = 0
        @avail = main - fixed - gaps
        @avail = 0 if @avail < 0

        lead = 0
        @just_leftover = 0
        @just_around = false
        @just_n = n
        @just_k = 0
        if grow == 0
          leftover = @avail
          case @justify
          when .center? then lead = leftover // 2
          when .end?    then lead = leftover
          when .space_between?
            # First child flush start, last flush end; leftover between them
            # carved by cumulative rounding in `#place`.
            @just_leftover = leftover
          when .space_around?
            # Equal space on both sides of every child (half-slot at each end).
            @just_leftover = leftover
            @just_around = true
          end
          # Lead for between/around is the cumulative offset before the first
          # child (0 for between, a half-slot for around).
          lead = justify_before(0) if @just_leftover > 0
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
            # Distribute @avail by cumulative rounding rather than rounding each
            # child's share independently: an independent `(@avail * grow) //
            # total_grow` floors every child, dropping up to `total_grow - 1`
            # columns at the far edge. Taking each child's size as the difference
            # of successive cumulative floors sums to exactly @avail (the last
            # flex child absorbs the remainder), matching Grid/Form.
            s =
              if @total_grow > 0
                before = (@avail * @grow_seen) // @total_grow
                @grow_seen += grow_of el
                (@avail * @grow_seen) // @total_grow - before
              else
                0
              end
            set_main_size el, s
            @flex << el
            s
          else
            # Reuse the size measured for this fixed child in `measure`.
            @measured[el]? || a_main_size el
          end

        set_main_pos el, @cursor
        # Advance past this child, its base `@gap`, and its share of the justify
        # leftover. The justify gap is the difference of successive cumulative
        # offsets (see `#justify_before`), so per-child gaps sum to exactly the
        # leftover and the last child lands flush against the far edge.
        gap_after = justify_before(@just_k + 1) - justify_before(@just_k)
        @just_k += 1
        @cursor += size + @gap + gap_after
      end

      # Cumulative justify offset laid down *before* the `j`-th placed child, so a
      # child's gap is `justify_before(k + 1) - justify_before(k)`. Sums to
      # `@just_leftover` exactly (no remainder stranded at the far edge),
      # mirroring the cumulative grow-share and Grid `#fence` distributions.
      #
      # * `SpaceBetween`: `j` of the `n - 1` gaps precede child `j`, i.e.
      #   `floor(j * leftover / (n - 1))` — 0 before the first, the whole leftover
      #   before the (notional) `n`-th, so the last child reaches the end.
      # * `SpaceAround`: each child sits in its own slot with a half-gap on each
      #   side, so `2j + 1` half-slots of `2n` precede child `j`:
      #   `floor((2j + 1) * leftover / (2n))`.
      private def justify_before(j : Int32) : Int32
        return 0 if @just_leftover == 0
        if @just_around
          return 0 if @just_n <= 0
          ((2 * j + 1) * @just_leftover) // (2 * @just_n)
        elsif @just_n > 1
          (j * @just_leftover) // (@just_n - 1)
        else
          0
        end
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
