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
    # * **`Widget#size_policy`** overrides that spec-derived split per axis:
    #   `Expanding` joins the flex share even over an explicit size,
    #   `Fixed` keeps the child's resolved size, and `Preferred` sizes the
    #   axis to `Widget#size_hint` (a label that sizes to its text with no
    #   explicit `width`). The default `Auto` derives from the spec as above.
    # * **`justify`** distributes leftover space along the main axis when no
    #   children grow (Start/Center/End/SpaceBetween/SpaceAround).
    # * **`align`** sets cross-axis placement: `Stretch` (default) fills the
    #   cross axis for children without an explicit cross size; `Start`/`Center`/
    #   `End` keep the child's own cross size and position it.
    #
    # A hidden child releases its slot: siblings pack as though it weren't there.
    #
    # Assigned positions/sizes go through the widget's layout-geometry channel
    # (`Widget#set_layout_geometry`), never the child's own `width`/`height`
    # specs — a nil spec means "this layout decides the axis", an explicit
    # spec means the child keeps it, and a stable layout emits no events
    # after the first frame (the write is change-guarded).
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

      # The main axis. Writable at runtime (Qt's `QBoxLayout::setDirection`):
      # flipping it re-arranges the children on the next frame.
      layout_property orientation, Tput::Orientation
      # `#spacing` (inter-child spacing) is inherited from `Layout`.

      # Leftover-space distribution along the main axis when nothing stretches;
      # change-guarded so a real change repaints the container.
      layout_property justify, Justify

      # Cross-axis placement of children without an explicit cross size;
      # change-guarded so a real change repaints the container.
      layout_property align, Align

      @cursor = 0
      @avail = 0
      # `@spacing` clamped against the live main extent each `#measure`
      # (negatives -> 0, over-extent -> the extent), stashed for `#place` since
      # it runs per child. Beyond the main extent there is no room anyway, and
      # clamping keeps the gap product and the cursor
      # accumulation from overflowing checked `Int32`.
      @spacing_gap = 0
      # `Int64` because `@avail * @grow_seen` (in `#place`) can exceed `Int32::MAX`
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

      # Appends *w* to the container — Qt's `QBoxLayout::addWidget(widget,
      # stretch, alignment)`, the canonical way to fill a box layout. A given
      # *stretch*/*align* is recorded as the child's `Hint`; with neither
      # given, an existing hint on the widget is left untouched. Returns *w*.
      #
      # ```
      # lay = window.layout = Crysterm::Layout::VBox.new
      # lay.add_widget header
      # lay.add_widget body, stretch: 2
      # lay.add_widget footer, align: :end
      # ```
      def add_widget(w : Widget, stretch : Int32? = nil, align : (Align | Shorthands)? = nil) : Widget
        c = require_container "Layout::Box#add_widget"
        apply_child_hint w, stretch, align
        c.append w
        w
      end

      # Inserts *w* at child position *index* — Qt's
      # `QBoxLayout::insertWidget`. See `#add_widget`.
      def insert_widget(index : Int32, w : Widget, stretch : Int32? = nil, align : (Align | Shorthands)? = nil) : Widget
        c = require_container "Layout::Box#insert_widget"
        apply_child_hint w, stretch, align
        c.insert w, index
        w
      end

      # Sets (or updates) *w*'s main-axis stretch factor — Qt's
      # `QBoxLayout::setStretchFactor` — without rebuilding the `Hint` by hand.
      def set_stretch(w : Widget, factor : Int32) : Nil
        hint = w.layout_hint.as?(Hint) || Hint.new
        hint.stretch = factor
        w.layout_hint = hint
        invalidate
      end

      # Sets (or clears, with `nil`) *w*'s cross-axis alignment override —
      # Qt's `QLayout::setAlignment(widget, alignment)`.
      def set_alignment(w : Widget, align : (Align | Shorthands)?) : Nil
        hint = w.layout_hint.as?(Hint) || Hint.new
        hint.alignment = align.nil? ? nil : ::Crystallabs::Helpers::Enums.from(Align, align)
        w.layout_hint = hint
        invalidate
      end

      private def apply_child_hint(w : Widget, stretch : Int32?, align : (Align | Shorthands)?) : Nil
        return if stretch.nil? && align.nil?
        hint = w.layout_hint.as?(Hint) || Hint.new
        stretch.try { |s| hint.stretch = s }
        align.try { |a| hint.alignment = ::Crystallabs::Helpers::Enums.from(Align, a) }
        w.layout_hint = hint
      end

      # Appends a fixed, inert *size*-cell gap to the box — Qt's
      # `QBoxLayout::addSpacing`. The gap is a real `Widget::Spacer` child
      # (non-focusable, invisible to hit-testing, paints nothing) whose
      # explicit size makes it a fixed main-axis slot in `#measure`. Lives on
      # the layout engine — like `Grid#add_widget`, `Form#add_row` and
      # `Stack#current_widget=`, the established home for container-addressing
      # layout mutators — and, like those, raises when the layout isn't
      # installed on a container yet. Returns the spacer (the `Grid#add_widget`
      # convention of returning the added widget), so a caller can remove or
      # resize it later.
      def add_spacing(size : Int32) : Widget::Spacer
        c = require_container "Layout::Box#add_spacing"
        sp = Widget::Spacer.new size
        c.append sp
        sp
      end

      # Appends a growing, inert gap taking *factor* shares of the leftover
      # main-axis space — Qt's `QBoxLayout::addStretch`. The gap is a real
      # `Widget::Spacer` child with no explicit size and a `Hint` carrying the
      # factor, so it participates in the box's normal grow distribution
      # (`#stretch_of`) alongside any other flex children — no parallel
      # mechanism. Returns the spacer; see `#add_spacing` for the design notes.
      def add_stretch(factor : Int32 = 1) : Widget::Spacer
        c = require_container "Layout::Box#add_stretch"
        sp = Widget::Spacer.stretch factor
        c.append sp
        sp
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
        # A hidden child not holding its slot (`#vacant?`) contributes no size,
        # grow weight, margin or gap, so `#each_occupying` skips it.
        each_occupying container do |el|
          n += 1
          margins += main_margin el
          if main_flex? el
            # `stretch_of` returns a clamped `Int32`; `grow` accumulates as
            # `Int64` since the *sum* over many children can still overflow.
            grow += stretch_of el
          else
            # The child's main size is its own spec this frame — or, under a
            # `Preferred` policy, its size hint — so quietly drop any stale
            # layout assignment from a frame it was still flex first, or
            # `a_main_size` reads that instead of the spec.
            clear_layout_main el
            ms =
              if main_policy(el).preferred?
                # `Preferred`: the hint is the ideal — never grown by the
                # engine, shrunk (via the extent clamp) when space runs
                # short. Assigned back through the layout channel in
                # `#place`, unlike a fixed child's spec-resolved size.
                clamped_size main_hint(el), main
              else
                # Clamp a fixed child's own resolved size against the main
                # extent before accumulating: an unclamped `Int32::MAX`-ish
                # size (a child's own `awidth`/`aheight` isn't bounded by
                # the parent) overflows checked `Int32` the moment a second
                # child's size is added.
                clamped_size a_main_size(el), main
              end
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

        cross = cross_extent interior
        main = main_extent interior

        # Cross axis. A per-child `Hint#alignment` overrides the box's `#align`.
        # `cross_pos` is always assigned; `cross_w` is the Int32 cross size to
        # write, or `nil` to leave the child's cross size untouched — the
        # nil-release path writes directly, since it must land before
        # `a_cross_size` reads it.
        align = align_of el
        cross_w : Int32? = nil
        if align.stretch?
          if cross_policy(el).preferred?
            # `Preferred` cross axis: assigned its size hint — never grown
            # to fill the slot, shrunk (via the clamp) when the interior or
            # the child's margins leave less room.
            cross_w = clamped_size cross_hint(el), margin_box(cross, cross_margin(el))
          elsif cross_flex? el
            # Fill the interior *minus* the child's cross-axis margins: the
            # assigned size is fixed and the render shift pushes it out by the
            # near margin, so a full-extent size would clip by `near + far`.
            cross_w = margin_box cross, cross_margin(el)
          end
          cross_pos = 0
        else
          # Align moved off Stretch (or a per-child `Hint#alignment` overrides
          # a still-Stretch box): the child keeps its own cross size this
          # frame, so quietly drop any stale layout assignment from a Stretch
          # frame before `a_cross_size` resolves the spec — otherwise the
          # child stays frozen at the last stretched extent.
          clear_layout_cross el

          # Position the child's whole *margin* box (`cs + cross_margin`), not its
          # border box: the render shift pushes the border box out by the near
          # margin, so an offset computed from `cross - cs` alone would overflow
          # the far edge and mis-center.
          cm = cross_margin el
          if cross_policy(el).preferred?
            # A `Preferred` child is sized to its hint here too — assigned
            # below, then positioned per the alignment like any own size.
            cs = clamped_size cross_hint(el), margin_box(cross, cm)
            cross_w = cs
          else
            cs = a_cross_size el
          end
          off = case align
                when .center? then (cross - cs - cm) // 2
                when .end?    then cross - cs - cm
                else               0
                end
          cross_pos = (off < 0 ? 0 : off)
        end

        # Main axis: a measured (non-flex) child keeps its measure; the rest
        # get a stretch-weighted share. `main_w` is the Int32 main size to
        # write — the flex share, or a `Preferred` child's measured hint (the
        # engine's decision, so it must be assigned) — or `nil` to leave a
        # fixed child to its own spec.
        main_pos = @cursor
        main_w : Int32? = nil
        if ms = @measured[el]?
          main_w = ms if main_policy(el).preferred?
        else
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
          main_w = s
        end

        # One coalesced layout-geometry write for both axes: a single `update`
        # (one ancestor-chain walk, at most one Move + one Resize) and the
        # child's own specs untouched. A `nil` size axis is unmanaged — the
        # child's spec rules (and any stale assignment clears). `0` is a real
        # size write.
        if orientation.horizontal?
          el.set_layout_geometry main_pos, cross_pos, main_w, cross_w
        else
          el.set_layout_geometry cross_pos, main_pos, cross_w, main_w
        end

        # Advance by the *clamped* used main size, read after the write: a CSS
        # min/max size makes the child render at `a_main_size`, so advancing by
        # the raw share would overlap the next child or leave a gap. An
        # unconstrained child clamps back to exactly the share. Also clamp
        # against the main extent: a min-size constraint can push
        # `a_main_size` arbitrarily high regardless of the share/`@avail`.
        size =
          if main_w
            clamped_size a_main_size(el), main
          else
            # Defensive-only: `main_w` is nil exactly for a measured non-
            # `Preferred` child (`@measured` is populated for every non-flex
            # child during the earlier measure pass, and a vacant child
            # returned above before either path) — so `@measured[el]?` never
            # actually misses here and the `clamped_size` fallback never
            # fires.
            @measured[el]? || clamped_size(a_main_size(el), main)
          end

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

      # Generates a mirror-image main/cross axis-dispatch pair from one
      # declaration: `main` evaluates `horiz` on a horizontal box and `vert` on a
      # vertical one, and `cross` is the identical body with the two arms swapped
      # — so the pair stays provably each other's inverse instead of by hand
      # (`Widget` uses the same `{% for %}` idiom for its paired size/position
      # accessors). The optional `ret` types both getters where their arms are
      # `Int32`; `main_size`/`cross_size` return the raw `Dim` union and so stay
      # unannotated. `main_extent`/`cross_extent` are the one pair left hand-written
      # below, taking a `RenderedGeometry` rather than a `Widget`.
      macro axis_pair(main, cross, horiz, vert, ret = nil)
        private def {{ main.id }}(el : Widget){% if ret %} : {{ ret.id }}{% end %}
          orientation.horizontal? ? {{ horiz }} : {{ vert }}
        end

        private def {{ cross.id }}(el : Widget){% if ret %} : {{ ret.id }}{% end %}
          orientation.horizontal? ? {{ vert }} : {{ horiz }}
        end
      end

      # The child's total margin (near + far) along the main / cross axis.
      axis_pair main_margin, cross_margin, el.mhorizontal, el.mvertical, Int32

      # Whether the child's main-axis size gets a grow share from this layout
      # — policy first: `Expanding` grows even over an explicit spec,
      # `Fixed`/`Preferred` never grow, and the default `Auto` derives the
      # answer from the spec — unset (`nil`) means this layout decides.
      # The spec test is exact by construction — this layout never writes the
      # specs, so a non-nil spec is always the user's, and setting one
      # (`child.width = 20`) reclaims the axis with no bookkeeping.
      private def main_flex?(el : Widget) : Bool
        case main_policy el
        in .auto?               then main_size(el).nil?
        in .expanding?          then true
        in .fixed?, .preferred? then false
        end
      end

      # Whether the child's cross-axis size is stretched to fill by this
      # layout; same policy-then-spec derivation as `main_flex?`.
      private def cross_flex?(el : Widget) : Bool
        case cross_policy el
        in .auto?               then cross_size(el).nil?
        in .expanding?          then true
        in .fixed?, .preferred? then false
        end
      end

      # Quietly drops the child's layout-assigned main / cross size — before
      # this engine resolves the child's own spec on that axis mid-arrange
      # (`a_main_size`/`a_cross_size` prefer a layout-assigned value, so a
      # stale one from a frame the axis was still layout-sized would shadow
      # the spec). The base `#clear_layout_sizes` clears both; these are the
      # single-axis forms the box's per-axis flow needs.
      private def clear_layout_main(el : Widget) : Nil
        orientation.horizontal? ? el.clear_layout_width : el.clear_layout_height
      end

      # :ditto:
      private def clear_layout_cross(el : Widget) : Nil
        orientation.horizontal? ? el.clear_layout_height : el.clear_layout_width
      end

      private def main_extent(interior : RenderedGeometry) : Int32
        orientation.horizontal? ? interior.width : interior.height
      end

      private def cross_extent(interior : RenderedGeometry) : Int32
        orientation.horizontal? ? interior.height : interior.width
      end

      # The child's raw (user-set) main / cross size — a `Dim` union, possibly nil.
      axis_pair main_size, cross_size, el.width, el.height

      # The child's resolved (`a*`) main / cross size in cells.
      axis_pair a_main_size, a_cross_size, el.awidth, el.aheight, Int32

      # The child's `Widget#size_policy` on the main / cross axis.
      axis_pair main_policy, cross_policy, el.size_policy.horizontal, el.size_policy.vertical, Widget::SizePolicy::Policy

      # The child's `Widget#size_hint` extent on the main / cross axis — the
      # size a `Preferred` axis is assigned.
      axis_pair main_hint, cross_hint, el.size_hint.width, el.size_hint.height, Int32
    end
  end
end
