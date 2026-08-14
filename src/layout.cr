module Crysterm
  # Base class for *child-arranging* layout engines.
  #
  # A layout is a strategy object installed on any container `Widget` via
  # `Widget#layout=`. Deliberately **not** a widget (cf. Qt's `QLayout`): the
  # container owns the on-window rectangle, border, padding and z-order slot;
  # the layout only decides where children go *inside* that rectangle.
  #
  # ### The contract
  #
  # Once the container has drawn itself and its `#lpos` is known,
  # `#render_children` computes the interior rectangle and hands it to the
  # single abstract method every engine implements:
  #
  # ```
  # abstract def arrange(container, interior)
  # ```
  #
  # `#arrange` owns the whole pass: it sets each child's geometry
  # (`left`/`top`/`width`/`height`) and renders it via `#render_child`, or omits
  # it / `#skip`s it. Owning the loop (rather than a per-child callback into a
  # fixed rectangle) lets the full range of layouts be expressed uniformly:
  #
  # * **flow** (`Masonry`, `Grid`) render each child *before* placing the next,
  #   so a content-sized child's real extent is known when laying out its
  #   neighbour;
  # * **box** (`HBox`, `VBox`) measure once, then place;
  # * **space-consuming** layouts (a future Border/Dock) shrink a working rect as
  #   they place each edge;
  # * **stacking** layouts (a future Stack/Card) give every child the same rect
  #   and `#skip` all but the active one.
  #
  # Engines needing extra per-child data (a Border region, a Grid cell+span, a
  # flex grow factor) define a `Layout::Hint` subclass and read it from
  # `Widget#layout_hint`.
  #
  # Table widgets (`Widget::Table`, `Widget::ListTable`) instead mix in the
  # separate *content* layout `TableLayout`: they lay out cell text inside their
  # own content rather than arranging child widgets, so they are not engines.
  abstract class Layout
    # Per-child placement hint. Engines requiring data beyond a child's own
    # `left`/`top`/`width`/`height` define a concrete subclass (a Border region,
    # a Grid `{row, column, row_span, column_span}`, a flex `grow` factor) and
    # read it off `Widget#layout_hint`.
    abstract class Hint
    end

    # Back-pointer to the container `Widget` this layout is installed on, set by
    # `Widget#layout=` (and cleared when the layout is replaced). Lets a
    # shape-changing setter schedule a repaint of the container it arranges, and
    # backs the container-addressing API (`Stack#current_widget`, `Form#add_row`).
    property container : Widget? = nil

    # `#container`, or raises when the layout isn't installed on one yet.
    # Every container-addressing mutator (`Box#add_spacing`/`#add_stretch`,
    # `Form#add_row`, `Grid#add_widget`) needs this same guard; *context* is
    # the raising call's own identity (e.g. `"Layout::Grid#add_widget"`),
    # interpolated into the one shared message so each site's exception text
    # stays whatever it already was.
    protected def require_container(context : String) : Widget
      container || raise ArgumentError.new "#{context}: layout not installed on a container"
    end

    # Schedules a repaint of the container, when installed. Called by the
    # shape-changing setters (`#spacing`, and the per-engine `justify`/`columns`/
    # ... below) so mutating a layout after the first frame re-arranges its
    # children — the layout analogue of `Widget#update`.
    protected def invalidate : Nil
      container.try &.update
    end

    # Declares a shape-changing layout knob: the `@name : type` ivar, its getter,
    # and a change-guarded setter that `#invalidate`s (repaints the container) on
    # a real change. Every layout property is exactly this — `#spacing` here, and
    # `justify`/`align`/`columns`/`rows`/`current_index`/`label_width`/
    # `horizontal_spacing`/`vertical_spacing` in the engines — so it lives here
    # once. The widget-side sibling is `Macros.repaint_property` (src/macros.cr),
    # including its convention of putting the property's doc comment immediately
    # above the macro call.
    #
    # *default* is optional: omit it for a property the subclass's `initialize`
    # assigns (`def initialize(@columns : Int32 = 2)`), which leaves the ivar
    # declared but unassigned — exactly what a plain `@columns : Int32` line did.
    # Macros defined in a class are visible in its subclasses, so an engine calls
    # this directly in its own body.
    macro layout_property(name, type, default = nil)
      {% if default != nil %}
        @{{ name.id }} : {{ type }} = {{ default }}
      {% else %}
        @{{ name.id }} : {{ type }}
      {% end %}

      def {{ name.id }} : {{ type }}
        @{{ name.id }}
      end

      def {{ name.id }}=(value : {{ type }}) : {{ type }}
        return value if value == @{{ name.id }}
        @{{ name.id }} = value
        invalidate
        value
      end
    end

    # Spacing between adjacent children, in cells — Qt's layout `spacing` under
    # its CSS name. Honored by the box/grid engines; the flow engines ignore it,
    # and `Form` uses its own `#horizontal_spacing`/`#vertical_spacing` instead.
    # Change-guarded; a real change repaints the container.
    layout_property spacing, Int32, 0

    # Sanitizes an inter-child spacing/gap against the axis extent it is laid
    # into: a negative value (which would overlap children) maps to 0, and any
    # value beyond `extent` already means "no room" so it caps there. Behavior-
    # preserving for sane spacings; it exists to keep a pathological spacing
    # (e.g. `Int32::MAX`) from overflowing the checked `Int32` gap products and
    # cursor accumulations in `#arrange`. Shared by `Box` and `Form`; `Grid`
    # clamps its own spacing internally against its `Int64` fence math.
    # Identical body to `#clamped_size` below (a spacing and a fixed size are
    # both just "a value clamped into the live extent") — kept as a separate,
    # differently-named entry point since the two read very differently at
    # each call site.
    protected def clamped_spacing(value : Int32, extent : Int32) : Int32
      clamped_size value, extent
    end

    # Sanitizes a child's resolved fixed main-axis size against the axis
    # extent it is laid into: a fixed size beyond the interior already means
    # "fills everything visible" (a huge child under no layout engine renders
    # clipped rather than crashing), so clamping is behavior-preserving.
    # Keeps a pathological (e.g. `Int32::MAX`) child size from overflowing
    # the checked `Int32` fixed-size sum/cursor accumulation in
    # `Box#measure`/`#place`.
    # Same clamp as `#clamped_spacing` above, under the name callers reach for
    # when the value in hand is a size rather than a spacing/gap.
    protected def clamped_size(v : Int32, extent : Int32) : Int32
      v.clamp(0, extent)
    end

    # The extent left for a child's *border* box after reserving its *margin*
    # box: `extent - margin`, floored at 0. Every packing engine needs this,
    # because the render pipeline shifts a fixed-size child outward by its near
    # margin without shrinking it — so handing the child the full `extent` would
    # make it paint `near + far` cells past its slot, over its neighbour. The
    # floor matters when the margins alone exceed the slot: a negative size is
    # not a size, and the child simply gets nothing.
    protected def margin_box(extent : Int32, margin : Int32) : Int32
      extent > margin ? extent - margin : 0
    end

    # Reused interior rectangle, mutated and returned by `#interior_coords` each
    # frame rather than allocating a `RenderedGeometry` per render. Safe only
    # because `#arrange` never retains it past the call and a layout instance
    # serves a single container.
    @interior_geometry = RenderedGeometry.new

    # Computes the container's interior content rectangle and, if non-empty,
    # delegates to `#arrange`.
    def render_children(container : Widget) : Nil
      interior = interior_coords container
      unless interior
        # Interior collapsed to nothing: the children paint nowhere this frame,
        # so clear their last-rendered rects — otherwise they'd stay
        # mouse-clickable/hoverable at the previous frame's positions.
        # Layout-excluded chrome renders out-of-band with its own live `lpos`,
        # so it's left untouched.
        each_arrangeable(container) { |el| skip_subtree el }
        render_chrome container
        return
      end
      arrange container, interior
      render_chrome container
    end

    # Arranges (and renders) the container's children within `interior` (the
    # absolute interior rectangle from `#interior_coords`). Implementations set
    # each child's geometry and render it via `#render_child`, or `#skip` it.
    abstract def arrange(container : Widget, interior : RenderedGeometry) : Nil

    # Renders the container's `layout_chrome?` children — a border label, a
    # bound scroll bar — after `#arrange`, each at its own pinned coordinates.
    # They are painted by the normal child pass but must not be *arranged* as
    # content slots, or an engine would tear the title off the border row or
    # turn a scroll bar into a flex cell. Runs last, so chrome paints on top of
    # the content it overlays.
    protected def render_chrome(container : Widget) : Nil
      container.children.each do |el|
        render_child el if el.layout_chrome?
      end
    end

    # Renders one child, performing the same render-index bookkeeping the
    # default (no-layout) loop in `Widget#base_render` does.
    protected def render_child(el : Widget) : Nil
      # Layout-excluded chrome (e.g. a `background-image` layer) renders
      # out-of-band, never through the child pass.
      return if el.layout_excluded?
      bump_index el
      render_or_defer el
    end

    # Renders `el` inline, or — when it carries a `z_index` and we aren't
    # already compositing a layer — defers it to its own plane (composited after
    # the base tree). While compositing a layer, nested layers flatten into the
    # enclosing plane and render inline.
    protected def render_or_defer(el : Widget) : Nil
      if deferred_this_frame? el
        # A deferred child renders later, on its own plane, so its `#_render`
        # (which clears `layout_suppressed`) hasn't run yet this frame. Clear the
        # flag here so a child skipped last frame isn't treated as still-suppressed
        # — otherwise `Flow#row_tallest` would drop a legitimately placed deferred
        # child from its row-height accounting.
        el.layout_suppressed = false
        el.window.defer_layer el
      else
        el.paint
      end
    end

    # Whether `el` will be composited on its own plane this frame rather than
    # rendered inline: it carries a `z_index` and we aren't already compositing a
    # layer (nested layers flatten into the enclosing plane). The single source
    # for the deferral test — `#render_or_defer` acts on it, and the flow engines
    # consult it for chain/row-height math, since a deferred child's `lpos` is not
    # refreshed until plane compositing and so within `#arrange` still holds the
    # previous frame's rect and must not anchor that math.
    protected def deferred_this_frame?(el : Widget) : Bool
      return false unless el.style.z_index
      !el.window.compositing_layers?
    end

    # Assigns the child its z-order/render index for this frame. Every child
    # must consume an index, even one later `#skip_subtree`d, or the ordering
    # drifts.
    protected def bump_index(el : Widget) : Nil
      if el.window.render_index_cursor != -1
        el.render_index = el.window.render_index_cursor
        el.window.render_index_cursor += 1
      end
    end

    # Marks `el`'s whole subtree as not rendered this frame. The whole subtree,
    # because hit-testing matches every widget independently against its own
    # `lpos`, so a stale grandchild rect would still take clicks even with the
    # parent's cleared. Also marks it suppressed, so focus/Tab navigation skips
    # the subtree (a non-current `Stack` page must not be a focus target).
    # Distinct from a scrolled-out widget, which is rendered (clearing the
    # flag) even when it lands off-viewport.
    #
    # Delegates to `Widget#suppress_subtree`, which prunes a subtree that is
    # already wholly suppressed (see the invariant documented there) — so
    # skipping the same hidden page on every arrange costs O(1), not a
    # re-walk of the page's entire subtree per rendered frame.
    protected def skip_subtree(el : Widget) : Nil
      el.suppress_subtree
    end

    # Assigns `el`'s full layout-managed rectangle in one call — through the
    # widget's *layout-geometry* fields (`Widget#set_layout_geometry`), never
    # the user's `left`/`top`/`width`/`height` specs, which stay exactly as
    # the user set them (a `"50%"` re-resolves every frame; an explicit spec
    # reclaims the axis with no bookkeeping). `nil` for a size leaves that
    # axis to the child's own spec (and clears any stale assignment from a
    # frame the axis was still managed).
    #
    # Does not render, so an engine placing several children before rendering
    # them stays in control of the order. One combined write: a single
    # `update` and at most one `Move` + one `Resize`, only for what actually
    # changed — a stable layout emits nothing after its first frame.
    protected def place_child(el : Widget, left : Int32, top : Int32, width : Int32?, height : Int32?) : Nil
      el.set_layout_geometry left, top, width, height
    end

    # Places `el`'s full rectangle and immediately renders it. Not for engines
    # that must place several children before rendering any of them (e.g. to
    # apply a shared row height to both) — those call `#place_child` and
    # `#render_child` separately.
    protected def place_and_render(el : Widget, left : Int32, top : Int32, width : Int32?, height : Int32?) : Nil
      place_child el, left, top, width, height
      render_child el
    end

    # Quietly drops both of `el`'s layout-assigned sizes, for an engine about
    # to resolve the child's own size specs mid-arrange (`awidth`/`aheight`
    # prefer a layout-assigned value, so a stale assignment from the previous
    # frame would shadow the spec — the layout-channel analogue of the old
    # restore-before-measure). Position assignments need no counterpart: no
    # engine reads a child's position spec back through `a*` before placing it.
    protected def clear_layout_sizes(el : Widget) : Nil
      el.clear_layout_width
      el.clear_layout_height
    end

    # Cumulative offset of fence line `i` when `total` is divided into `n`
    # equal-as-possible parts: `floor(i * total / n)`. Successive fences give
    # each part `fence(i + 1) - fence(i)`, summing to exactly `total` with the
    # last part absorbing the remainder — the technique `Grid` uses to carve
    # columns/rows (and `Box`, in a weighted variant, its grow-share/justify
    # leftover). `i` is clamped to `0..n` so an off-grid span stops at the edge.
    # Pure (no instance state), hence a class method; allocates nothing.
    #
    # `i * total` runs in `Int64`: callers clamp `i` to `n`, but not `total`
    # (an interior extent) against `i`, so ordinary-sized interiors combined
    # with a large `n`/`i` (an off-grid span) can still exceed `Int32::MAX`
    # before the division. The quotient is always within `0..total`, so
    # narrowing the result back to `Int32` is safe.
    def self.fence(total : Int32, n : Int32, i : Int32) : Int32
      i = i.clamp(0, n)
      (i.to_i64 * total // n).to_i32
    end

    # Yields each of the container's *arrangeable* children — the ones an engine
    # actually positions — skipping both `layout_excluded?` chrome (e.g. a
    # `background-image` layer or out-of-band scrollbar, rendered separately from
    # `Widget#base_render` with its own full-interior `lpos`) and `layout_chrome?`
    # chrome (a border label or bound scroll bar, painted by `#render_chrome` at
    # its own pinned coordinates). Neither kind may consume a gap, a `justify`/
    # page slot, a grid cell, a form label/field, a dock region, nor inflate a
    # flow row, so this lives here once instead of per engine. Block-yielding, so
    # it allocates nothing per frame.
    protected def each_arrangeable(container : Widget, &) : Nil
      container.children.each do |el|
        next unless arrangeable?(el)
        yield el
      end
    end

    # Whether an engine actually positions `el` this frame: it is neither
    # `layout_excluded?` chrome (rendered out-of-band with its own `lpos`) nor
    # `layout_chrome?` chrome (pinned and painted by `#render_chrome`). The
    # single predicate every arrangeable-child filter routes through, so a future
    # chrome flavor is one edit; inlined, so the sites cost nothing.
    @[AlwaysInline]
    protected def arrangeable?(el : Widget) : Bool
      !el.layout_excluded? && !el.layout_chrome?
    end

    # Whether *el* takes up no space this frame and the engine should pack as
    # though it weren't there: it is hidden and hasn't asked to keep its slot
    # (`Widget#retain_size_when_hidden?`). Qt's `QWidgetItem#isEmpty`.
    #
    # Only the *packing* engines consult this — `Layout::Box` (VBox/HBox),
    # `Layout::Border` and the `Flow` family (Wrap/Masonry/UniformGrid) —
    # where "give the space back" is the unambiguous reading and the one Qt's
    # `QBoxLayout` implements. `Layout::Stack` and `Layout::Grid` address
    # their children by slot (page index, cell), so a hidden child there must
    # keep its position; they ignore this, as `QStackedLayout`/`QGridLayout` do.
    #
    # Reads `#visible?` (the node's own flag — Qt's `isHidden`), not
    # `#visible_in_tree?`: a hidden ancestor's subtree never arranges anyway.
    protected def vacant?(el : Widget) : Bool
      !el.visible? && !el.retain_size_when_hidden?
    end

    # `#each_arrangeable`, minus the children that are `#vacant?` this frame.
    # The iteration packing engines want.
    protected def each_occupying(container : Widget, &) : Nil
      each_arrangeable(container) do |el|
        yield el unless vacant? el
      end
    end

    # Number of arrangeable (non-`layout_excluded?`, non-`layout_chrome?`)
    # children — the slot/page count engines size their distribution against.
    protected def arrangeable_count(container : Widget) : Int32
      container.children.count { |el| arrangeable?(el) }
    end

    # The container's interior content rectangle (inside border + padding), in
    # absolute window coordinates, or nil if collapsed to nothing.
    # `container.lpos` is already up to date by the time children render, so
    # this reads it directly rather than re-deriving coordinates.
    protected def interior_coords(container : Widget) : RenderedGeometry?
      lpos = container.lpos
      return unless lpos
      xi = lpos.xi + container.ileft
      xl = lpos.xl - container.iright
      yi = lpos.yi + container.itop
      yl = lpos.yl - container.ibottom
      return if (xl - xi <= 0) || (yl - yi <= 0)
      i = @interior_geometry
      i.xi = xi
      i.xl = xl
      i.yi = yi
      i.yl = yl
      i
    end

    # `el`'s rendered rectangle from the last frame if **non-empty**, else nil.
    # Lets layout callers bind the rectangle directly instead of re-reading it
    # through a `not_nil!` after a separate `#rendered?` check.
    #
    # Deliberately *not* `Widget#last_rendered_position?`: that reports a
    # rectangle whenever one exists, whereas an engine chaining one child off
    # the previous one must treat a collapsed (zero-width/height) rectangle as
    # "nothing rendered" — otherwise a placed-but-empty child anchors its
    # neighbour. `#rendered?` is defined in terms of this, so the two agree.
    @[AlwaysInline]
    protected def rendered_geometry(el : Widget) : RenderedGeometry?
      return unless l = el.lpos
      (l.width > 0) && (l.height > 0) ? l : nil
    end

    # Whether `el` produced a non-empty rendered rectangle on the last frame.
    protected def rendered?(el : Widget) : Bool
      !rendered_geometry(el).nil?
    end
  end
end

# The abstract `Flow` strategy base subclasses `Layout`, so it's required after
# the base above is defined; its concrete engines (Masonry, UniformGrid, Wrap)
# live under `src/layout/`.
