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

    # Schedules a repaint of the container, when installed. Called by the
    # shape-changing setters (`#spacing`, and the per-engine `justify`/`columns`/
    # ... below) so mutating a layout after the first frame re-arranges its
    # children — the layout analogue of `Widget#mark_dirty`.
    protected def invalidate : Nil
      container.try &.mark_dirty
    end

    # Spacing between adjacent children, in cells — Qt's layout `spacing` under
    # its CSS name. Honored by the box/grid engines; the flow engines ignore it,
    # and `Form` uses its own `#horizontal_spacing`/`#vertical_spacing` instead.
    @spacing : Int32 = 0

    # :ditto:
    def spacing : Int32
      @spacing
    end

    # :ditto: — change-guarded; a real change repaints the container.
    def spacing=(value : Int32) : Int32
      return value if value == @spacing
      @spacing = value
      invalidate
      value
    end

    # Sanitizes an inter-child spacing/gap against the axis extent it is laid
    # into: a negative value (which would overlap children) maps to 0, and any
    # value beyond `extent` already means "no room" so it caps there. Behavior-
    # preserving for sane spacings; it exists to keep a pathological spacing
    # (e.g. `Int32::MAX`) from overflowing the checked `Int32` gap products and
    # cursor accumulations in `#arrange`. Shared by `Box` and `Form`; `Grid`
    # clamps its own spacing internally against its `Int64` fence math.
    protected def clamped_spacing(value : Int32, extent : Int32) : Int32
      value.clamp(0, extent)
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
    # default (no-layout) loop in `Widget#_render` does.
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
      scr = el.window
      if el.style.z_index && !scr.compositing_layers?
        # A deferred child renders later, on its own plane, so its `#_render`
        # (which clears `layout_suppressed`) hasn't run yet this frame. Clear the
        # flag here so a child skipped last frame isn't treated as still-suppressed
        # — otherwise `Flow#row_tallest` would drop a legitimately placed deferred
        # child from its row-height accounting.
        el.layout_suppressed = false
        scr.defer_layer el
      else
        el.render
      end
    end

    # Assigns the child its z-order/render index for this frame. Every child
    # must consume an index, even one later `#skip`ped, or the ordering drifts.
    protected def bump_index(el : Widget) : Nil
      if el.window.render_index_cursor != -1
        el.render_index = el.window.render_index_cursor
        el.window.render_index_cursor += 1
      end
    end

    # Marks `el` as not rendered this frame (clears its last position).
    protected def skip(el : Widget) : Nil
      el.lpos = nil
    end

    # Marks `el`'s whole subtree as not rendered this frame. The whole subtree,
    # because hit-testing matches every widget independently against its own
    # `lpos`, so a stale grandchild rect would still take clicks even with the
    # parent's cleared. Explicit recursion (no captured block) keeps this
    # allocation-free.
    protected def skip_subtree(el : Widget) : Nil
      el.lpos = nil
      # Suppressed, so focus/Tab navigation skips the subtree (a non-current
      # `Stack` page must not be a focus target). Distinct from a scrolled-out
      # widget, which is rendered (clearing the flag) even when it lands
      # off-viewport.
      el.layout_suppressed = true
      el.children.each { |c| skip_subtree c }
    end

    # Assigns `el`'s full rectangle (left/top/width/height) in one call. Does not
    # render, so an engine placing several children before rendering them stays
    # in control of the order. One combined geometry write, so the whole
    # rectangle costs a single `mark_dirty` and at most one `Move` + one
    # `Resize`, rather than four independent setter runs.
    protected def place_child(el : Widget, left : Int32, top : Int32, width : Int32, height : Int32) : Nil
      el.set_geometry left, top, width, height
    end

    # Places `el`'s full rectangle and immediately renders it. Not for engines
    # that must place several children before rendering any of them (e.g. to
    # apply a shared row height to both) — those call `#place_child` and
    # `#render_child` separately.
    protected def place_and_render(el : Widget, left : Int32, top : Int32, width : Int32, height : Int32) : Nil
      place_child el, left, top, width, height
      render_child el
    end

    # --- Layout-owned ("managed") size bookkeeping -------------------------
    #
    # An engine that resolves a child's raw size to cells and writes the
    # resolved `Int32` back would *destroy* the original value: a `"50%"` string
    # would never resolve again (frozen at frame 1's cell count), an auto size
    # would freeze, a transient clamp would stick. So an engine keeps a
    # `raw_map` (the value the user set) beside an `assigned_map` (the Int it
    # last wrote), restoring the raw value before re-measuring and releasing a
    # child once its raw size no longer equals what was assigned. These helpers
    # single-source that core; the caller supplies the per-engine axis/field.
    # All three are allocation-free — the blocks are `yield`ed, never captured.

    # Drops bookkeeping entries for children that have left `container`.
    # Hash-shaped maps only (two-arg block); a `Set`-backed tracker prunes with
    # a one-arg `select!` inline.
    protected def prune_managed(container : Widget, map) : Nil
      map.select! { |el, _| container.child? el }
    end

    # Restores `el`'s remembered raw size (passed in as `raw`) before a
    # re-measure — so a percent/nil/clamped size resolves against the *live*
    # container every frame — or, when the raw size no longer equals what was
    # last assigned, forgets the old value and records the new one (the user
    # reclaimed the child). The block receives the remembered raw value and
    # writes it back into the child's axis.
    protected def restore_managed(el : Widget, raw_map, assigned_map, raw, &) : Nil
      if (assigned = assigned_map[el]?) && raw == assigned && raw_map.has_key?(el)
        yield raw_map[el]
      else
        raw_map[el] = raw
      end
    end

    # Remembers the resolved `Int32` just written into `el`, so the next frame
    # can tell a layout-owned size from a user-reclaimed one.
    protected def record_managed(el : Widget, assigned_map, v : Int32) : Nil
      assigned_map[el] = v
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
    # `Widget#_render` with its own full-interior `lpos`) and `layout_chrome?`
    # chrome (a border label or bound scroll bar, painted by `#render_chrome` at
    # its own pinned coordinates). Neither kind may consume a gap, a `justify`/
    # page slot, a grid cell, a form label/field, a dock region, nor inflate a
    # flow row, so this lives here once instead of per engine. Block-yielding, so
    # it allocates nothing per frame.
    protected def each_arrangeable(container : Widget, &) : Nil
      container.children.each do |el|
        next if el.layout_excluded? || el.layout_chrome?
        yield el
      end
    end

    # Whether *el* takes up no space this frame and the engine should pack as
    # though it weren't there: it is hidden and hasn't asked to keep its slot
    # (`Widget#retain_size_when_hidden?`). Qt's `QWidgetItem#isEmpty`.
    #
    # Only the *packing* engines consult this — `Layout::Box` (VBox/HBox) and
    # `Layout::Border` — where "give the space back" is the unambiguous reading
    # and the one Qt's `QBoxLayout` implements. `Layout::Stack` and
    # `Layout::Grid` address their children by slot (page index, cell), so a
    # hidden child there must keep its position; they ignore this, as
    # `QStackedLayout`/`QGridLayout` do.
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
      container.children.count { |el| !el.layout_excluded? && !el.layout_chrome? }
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
      return nil unless l = el.lpos
      (l.width > 0) && (l.height > 0) ? l : nil
    end

    # Whether `el` produced a non-empty rendered rectangle on the last frame.
    protected def rendered?(el : Widget) : Bool
      !rendered_geometry(el).nil?
    end

    # The most recently *rendered* child before index `i` (skipping children
    # that collapsed to nothing last frame), or nil if none.
    #
    # Layout-excluded and `layout_chrome?` chrome are skipped too: a
    # `background-image` layer (`layout_excluded?`) or a border label / bound
    # scroll bar (`layout_chrome?`) is rendered out-of-band (with a full-interior
    # or pinned `lpos`) yet still lives in `children`. Without this guard a flow
    # child appended after such chrome would chain its left edge off the chrome's
    # rect instead of off the previous flow child.
    protected def last_rendered_before(container : Widget, i : Int32) : Widget?
      while i > 0
        i -= 1
        el = container.children[i]
        next if el.layout_excluded? || el.layout_chrome?
        return el if rendered? el
      end
      nil
    end
  end
end

# The abstract `Flow` strategy base subclasses `Layout`, so it's required after
# the base above is defined; its concrete engines (Masonry, UniformGrid, Wrap)
# live under `src/layout/`.
require "./layout_flow"
