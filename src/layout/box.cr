require "../layout"

module Crysterm
  class Layout
    # Single-axis box layout — the shared engine behind `HBox` and `VBox`
    # (cf. Qt's `QHBoxLayout`/`QVBoxLayout`), with CSS-flexbox-style sizing.
    # Children are laid end-to-end along the main axis (horizontal for `HBox`,
    # vertical for `VBox`), separated by `spacing` cells.
    #
    # * **Main axis:** a child with an explicit main-axis size keeps it; the rest
    #   share the leftover space in proportion to their `stretch` factor (default
    #   1, i.e. equal shares). Set a per-child factor with
    #   `layout_hint: Layout::Box::Hint.new(stretch: 2)`.
    # * **`justify`** distributes leftover space along the main axis when no
    #   children grow (Start/Center/End/SpaceBetween/SpaceAround).
    # * **`align`** sets cross-axis placement: `Stretch` (default) fills the
    #   cross axis for children without an explicit cross size; `Start`/`Center`/
    #   `End` keep the child's own cross size and position it.
    #
    # A hidden child releases its slot: siblings pack as though it weren't there.
    #
    # Assigned sizes are remembered (`@flex`/`@filled`) so a sized child stays
    # recognised as managed, and reassigned through the normal setters (no-op
    # when unchanged) so a stable layout emits no events after the first frame.
    class Box < Layout
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

      # Per-child main-axis stretch factor (proportional share of leftover space),
      # plus an optional per-child cross-axis `alignment` that overrides the box's
      # own `#align`.
      class Hint < Layout::Hint
        property stretch : Int32
        # Cross-axis alignment for *this* child; `nil` defers to the box `#align`.
        property alignment : Align? = nil

        def initialize(@stretch : Int32 = 1, @alignment : Align? = nil)
        end
      end

      getter orientation : Tput::Orientation
      # `#spacing` (inter-child spacing) is inherited from `Layout`.

      # Leftover-space distribution along the main axis when nothing stretches;
      # change-guarded so a real change repaints the container.
      @justify : Justify

      # :ditto:
      def justify : Justify
        @justify
      end

      # :ditto:
      def justify=(value : Justify) : Justify
        return value if value == @justify
        @justify = value
        invalidate
        value
      end

      # Cross-axis placement of children without an explicit cross size;
      # change-guarded so a real change repaints the container.
      @align : Align

      # :ditto:
      def align : Align
        @align
      end

      # :ditto:
      def align=(value : Align) : Align
        return value if value == @align
        @align = value
        invalidate
        value
      end

      @cursor = 0
      @avail = 0
      # `@spacing` clamped against the live main extent each `#measure`
      # (negatives -> 0, over-extent -> the extent), stashed for `#place` since
      # it runs per child. Beyond the main extent there is no room anyway, so
      # this is behavior-preserving while keeping the gap product and the cursor
      # accumulation from overflowing checked `Int32` (B17-10).
      @spacing_gap = 0
      # `Int64` because `@avail * @grow_seen` (line ~247) can exceed `Int32::MAX`
      # well before either factor does; stretch factors are clamped in
      # `#stretch_of` but the *sum* over many children is not.
      @total_grow : Int64 = 0
      # Running sum of grow factors of flex children placed so far; distributes
      # `@avail` by cumulative rounding. Reset each measure, consumed in place order.
      @grow_seen : Int64 = 0
      # Leftover space distributed along the main axis by `justify` when nothing
      # grows, carved into per-child gaps by *cumulative* rounding rather than a
      # floored `leftover // slots`, which strands up to `slots - 1` columns.
      # `@just_n` is the arranged-child count, `@just_k` the placement ordinal.
      @just_leftover = 0
      @just_n = 0
      @just_around = false
      @just_k = 0
      @flex = Set(Widget).new
      @filled = Set(Widget).new
      # Last main/cross size this layout *assigned* to a flex/filled child.
      # `@flex`/`@filled` alone can't tell a layout-assigned size from a fresh
      # user-set one, so a member counts as managed only while its raw size still
      # equals what was last put there; a mismatch means the user reclaimed it.
      @flex_size = {} of Widget => Int32
      @filled_size = {} of Widget => Int32
      # Per-arrange cache of fixed children's resolved main-axis size, so the
      # ancestor-chain walk in `a_main_size` runs once per frame, not per pass.
      # Stable between passes since only cross-axis size changes in between.
      @measured = {} of Widget => Int32

      def initialize(
        @orientation : Tput::Orientation = Tput::Orientation::Horizontal,
        @spacing : Int32 = 0,
        @justify : Justify = Justify::Start,
        @align : Align = Align::Stretch,
      )
      end

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        measure container, interior
        each_arrangeable container do |el|
          place el, interior
          render_child el
        end
      end

      # Measures the main axis: total fixed size, total grow weight, the leftover
      # to distribute, and (when nothing grows) the `justify` lead/extra-gap.
      private def measure(container : Widget, interior : RenderedGeometry) : Nil
        # `child?` is O(1); a linear membership test here would make pruning
        # O(tracked × children) per arrange.
        @flex.select! { |el| container.child? el }
        @filled.select! { |el| container.child? el }
        prune_managed container, @flex_size
        prune_managed container, @filled_size

        main = main_extent interior
        # Clamp spacing before any gap product/accumulation: a raw `@spacing`
        # near `Int32::MAX` (or negative) would overflow/under-allocate here.
        sp = clamped_spacing @spacing, main
        @spacing_gap = sp

        fixed = 0
        grow = 0_i64
        # The render pipeline shifts every laid child outward by its near margin,
        # and a Box-assigned size is a fixed `Int32` that never folds its margin
        # in, so the packing must reserve both main-axis margins — otherwise
        # children overlap and flex over-allocates.
        margins = 0
        @measured.clear
        # Only arranged children count: layout-excluded chrome must not consume a
        # gap or justify slot.
        n = 0
        each_arrangeable container do |el|
          # A hidden child not holding its slot contributes no size, grow weight,
          # margin or gap.
          next if vacant? el
          n += 1
          margins += main_margin el
          if main_flex? el
            # `stretch_of` returns a clamped `Int32`; `grow` accumulates as
            # `Int64` since the *sum* over many children can still overflow.
            grow += stretch_of el
          else
            # Clamp a fixed child's own resolved size against the main extent
            # before accumulating: an unclamped `Int32::MAX`-ish size (a
            # child's own `awidth`/`aheight` isn't bounded by the parent)
            # overflows checked `Int32` the moment a second child's size is
            # added (B18-25).
            ms = clamped_size a_main_size(el), main
            @measured[el] = ms
            fixed += ms
          end
        end
        gaps = n > 1 ? sp * (n - 1) : 0

        @total_grow = grow
        @grow_seen = 0_i64
        @avail = main - fixed - gaps - margins
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
            # First child flush start, last flush end.
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

      private def place(el : Widget, interior : RenderedGeometry) : Nil
        # A vacant child was never measured, so it takes no position and must not
        # advance `@cursor` or consume a justify slot. Its stale geometry is
        # harmless: it paints nothing while hidden, and showing it re-measures it.
        return if vacant? el

        # Cross axis. A per-child `Hint#alignment` overrides the box's `#align`.
        cross = cross_extent interior
        align = align_of el
        if align.stretch?
          if cross_flex? el
            # Fill the interior *minus* the child's cross-axis margins: the
            # assigned size is fixed and the render shift pushes it out by the
            # near margin, so a full-extent size would clip by `near + far`.
            cs = cross - cross_margin(el)
            cs = 0 if cs < 0
            set_cross_size el, cs
            @filled << el
            @filled_size[el] = cs
          end
          set_cross_pos el, 0
        else
          # Align moved off Stretch (or a per-child `Hint#alignment` overrides
          # a still-Stretch box) — release a cross size this layout previously
          # assigned back to the user's raw `nil` before measuring, mirroring
          # Form's restore-before-measure (B16-17). Without this the child
          # stays frozen at whatever cross extent the Stretch branch last
          # wrote forever: it stops tracking container resizes and the user's
          # raw `nil` (auto) is destroyed for good (B18-23). Safe: a child only
          # ever enters `@filled` when its raw cross size was `nil` (the
          # `cross_flex?` membership test), so `nil` is always the correct
          # value to restore; a user-reclaimed explicit size (raw no longer
          # matches `@filled_size`) fails the guard and is left untouched.
          if @filled.includes?(el) && cross_size(el) == @filled_size[el]?
            set_cross_size el, nil
            @filled.delete el
            @filled_size.delete el
          end

          # Position the child's whole *margin* box (`cs + cross_margin`), not its
          # border box: the render shift pushes the border box out by the near
          # margin, so an offset computed from `cross - cs` alone would overflow
          # the far edge and mis-center.
          cs = a_cross_size el
          cm = cross_margin el
          off = case align
                when .center? then (cross - cs - cm) // 2
                when .end?    then cross - cs - cm
                else               0
                end
          set_cross_pos el, (off < 0 ? 0 : off)
        end

        # Main axis: explicit size wins; otherwise a stretch-weighted share.
        main = main_extent interior
        size =
          if !@measured.has_key?(el)
            # Cumulative rounding: each child's size is the difference of
            # successive cumulative floors, which sums to exactly `@avail`.
            # Rounding each share independently would floor every child and
            # strand up to `total_grow - 1` columns at the far edge.
            s =
              if @total_grow > 0
                # `@avail * @grow_seen` overflows `Int32` well before either
                # factor reaches `Int32::MAX`, so the share math runs in
                # `Int64`; the result is always within `0..@avail`, so the
                # narrowing back to `Int32` is safe.
                avail64 = @avail.to_i64
                before = (avail64 * @grow_seen) // @total_grow
                @grow_seen += stretch_of el
                ((avail64 * @grow_seen) // @total_grow - before).to_i32
              else
                0
              end
            set_main_size el, s
            @flex << el
            @flex_size[el] = s
            # Advance by the *clamped* used size, not the raw share `s`: a CSS
            # min/max size makes the child render at `a_main_size`, so advancing
            # by `s` would overlap the next child or leave a gap. An
            # unconstrained child clamps back to exactly `s`. Also clamp against
            # the main extent (B18-25): a min-size constraint can push
            # `a_main_size` arbitrarily high regardless of `s`/`@avail`.
            clamped_size a_main_size(el), main
          else
            @measured[el]? || clamped_size(a_main_size(el), main)
          end

        set_main_pos el, @cursor
        gap_after = justify_before(@just_k + 1) - justify_before(@just_k)
        @just_k += 1
        # Advance past this child's whole *margin* box, plus the base gap and its
        # justify share. Without the margin term the next child's `@cursor` would
        # land inside this one.
        @cursor += size + main_margin(el) + @spacing_gap + gap_after
      end

      # Cumulative justify offset laid down *before* the `j`-th placed child, so a
      # child's gap is `justify_before(k + 1) - justify_before(k)`. Sums to
      # `@just_leftover` exactly, stranding no remainder at the far edge.
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

      # Clamped to a sane range: a pathological (huge or negative) per-child
      # factor must not overflow the grow accumulation/share math below.
      # Negatives map to 0 (no share of leftover, same as an explicit `stretch:
      # 0` — CSS `flex-grow: 0` / Qt stretch 0), not the default of 1.
      private def stretch_of(el : Widget) : Int32
        ((el.layout_hint.as?(Hint)).try(&.stretch) || 1).clamp(0, 1_000_000)
      end

      # This child's cross-axis alignment: its `Hint#alignment` when set, else the
      # box's own `#align`.
      private def align_of(el : Widget) : Align
        (el.layout_hint.as?(Hint)).try(&.alignment) || @align
      end

      # The child's total margin along the main axis (near + far).
      private def main_margin(el : Widget) : Int32
        orientation.horizontal? ? el.mhorizontal : el.mvertical
      end

      # The child's total margin along the cross axis.
      private def cross_margin(el : Widget) : Int32
        orientation.horizontal? ? el.mvertical : el.mhorizontal
      end

      # Whether the child's main-axis size is decided by this layout: either its
      # raw size is unset (`nil`), or we assigned it and it still holds that
      # value. If the raw size no longer matches what we last assigned, the user
      # reclaimed the child (`child.width = 20`), so it reverts to fixed.
      private def main_flex?(el : Widget) : Bool
        main_size(el).nil? || (@flex.includes?(el) && main_size(el) == @flex_size[el]?)
      end

      # Whether the child's cross-axis size is decided (stretched) by this layout;
      # released the same way as `main_flex?` when the user sets an explicit size.
      private def cross_flex?(el : Widget) : Bool
        cross_size(el).nil? || (@filled.includes?(el) && cross_size(el) == @filled_size[el]?)
      end

      private def main_extent(interior : RenderedGeometry) : Int32
        orientation.horizontal? ? interior.width : interior.height
      end

      private def cross_extent(interior : RenderedGeometry) : Int32
        orientation.horizontal? ? interior.height : interior.width
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
