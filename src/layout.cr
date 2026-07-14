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
  # Once the container has drawn itself and its `#lpos` is known, `Widget#_render`
  # calls `#render_children`, which computes the interior rectangle and hands it
  # to the single abstract method every engine implements:
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
    # `left`/`top`/`width`/`height` define a concrete subclass (e.g. a Border
    # region, a Grid `{row, col, row_span, col_span}`, a flex `grow` factor) and
    # read it off `Widget#layout_hint`. Open extension point for new engines.
    abstract class Hint
    end

    # Spacing between adjacent children, in cells (Qt's layout `spacing`, CSS
    # `spacing`). Lives on the base so it can be set uniformly (e.g. from CSS via
    # `Geometry.apply`) regardless of engine. Honored by box/grid/form engines;
    # flow engines (`Masonry`/`Wrap`/`UniformGrid`) currently ignore it.
    property gap : Int32 = 0

    # Reused interior rectangle, mutated and returned by `#interior_coords` each
    # frame instead of allocating a fresh `LPos` per render. `#arrange` reads
    # only its four coordinates and never retains it past the call, and a layout
    # instance serves a single container, so one cached rectangle is safe.
    @interior_lpos = LPos.new

    # Entry point invoked by `Widget#_render`. Computes the container's interior
    # content rectangle and, if non-empty, delegates to `#arrange`.
    def render_children(container : Widget) : Nil
      interior = interior_coords container
      unless interior
        # Interior collapsed to nothing: the children paint nowhere this frame,
        # so clear their last-rendered rects — otherwise they'd stay
        # mouse-clickable/hoverable at the previous frame's positions (same
        # rationale as `Flow#arrange`'s `StopRendering` branch). Layout-excluded
        # chrome renders out-of-band with its own live `lpos`, so it's left
        # untouched.
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
    abstract def arrange(container : Widget, interior : LPos) : Nil

    # Renders the container's *chrome* children — a border label or a bound
    # scroll bar (`Widget#layout_chrome?`) — after `#arrange`. Unlike
    # `layout_excluded?` chrome (rendered fully out-of-band from `Widget#_render`
    # and skipped by `#render_child`), these are painted by the normal child pass
    # but must not be *arranged* (measured/placed) as content slots: an installed
    # engine would otherwise tear the title off the border row or turn a scroll
    # bar into a flex cell (see finding — `#each_arrangeable` skips them). So the
    # engine skips arranging them and this paints each at its own pinned
    # coordinates. `Layout::Manual` renders every child (chrome included) through
    # `#render_child` already and overrides `#render_children`, so it never
    # reaches here — no double render. Rendered last, chrome paints on top of the
    # content it overlays, as intended.
    protected def render_chrome(container : Widget) : Nil
      container.children.each do |el|
        render_child el if el.layout_chrome?
      end
    end

    # Renders one child, performing the same render-index bookkeeping the
    # default (no-layout) loop in `Widget#_render` does.
    protected def render_child(el : Widget) : Nil
      # Layout-excluded chrome (e.g. a `background-image` layer) renders
      # out-of-band from `Widget#_render`, never through the child pass.
      return if el.layout_excluded?
      bump_index el
      render_or_defer el
    end

    # Renders `el` inline, or — when it carries a `z_index` and we aren't
    # already compositing a layer — defers it to its own plane (composited after
    # the base tree); while compositing a layer, nested layers flatten into the
    # enclosing plane and render inline. Split from `#render_child` (which also
    # bumps the render index) so flow/stack engines, which bump every child
    # themselves, can still honor the z-index deferral.
    protected def render_or_defer(el : Widget) : Nil
      scr = el.window
      if el.style.z_index && !scr.compositing_layers?
        scr.defer_layer el
      else
        el.render
      end
    end

    # Assigns the child its z-order/render index for this frame. Split out from
    # `#render_child` so flow engines keep the index bookkeeping consistent
    # (every child consumes an index, even one later `#skip`ped) while still
    # controlling whether the child renders.
    protected def bump_index(el : Widget) : Nil
      if el.window._ci != -1
        el.index = el.window._ci
        el.window._ci += 1
      end
    end

    # Marks `el` as not rendered this frame (clears its last position).
    protected def skip(el : Widget) : Nil
      el.lpos = nil
    end

    # Marks `el`'s whole subtree as not rendered this frame. An unrendered
    # widget's descendants paint nothing either, but `Window#widget_at`
    # hit-tests every widget independently against its own `lpos`, so a stale
    # grandchild rect would still take clicks even with the parent's cleared.
    # Explicit recursion (no captured block) keeps this allocation-free.
    protected def skip_subtree(el : Widget) : Nil
      el.lpos = nil
      # Mark the subtree layout-suppressed so focus/Tab navigation skips it (a
      # non-current `Stack` page must not be a focus target — see
      # `Widget#layout_suppressed?`). Distinct from a scrolled-out widget, which
      # is rendered (clearing the flag) even when it lands off-viewport.
      el.layout_suppressed = true
      el.children.each { |c| skip_subtree c }
    end

    # Assigns `el`'s full rectangle (left/top/width/height) in one call — the
    # four-assignment geometry block the rectangular engines (`Border`, `Form`)
    # would otherwise repeat at every placement. Does not render; the caller
    # follows with `#render_child` (so engines placing several children before
    # rendering them, e.g. `Form`'s label/field pair, stay in control of order).
    protected def place_child(el : Widget, left : Int32, top : Int32, width : Int32, height : Int32) : Nil
      # One combined geometry write: a single `mark_dirty` (parent-chain walk +
      # minrect invalidation + window-damage registration) and at most one
      # `Move` + one `Resize` for the whole rectangle, rather than four
      # independent setter runs. See `Widget#set_geometry`.
      el.set_geometry left, top, width, height
    end

    # Places `el`'s full rectangle and immediately renders it — the
    # place-then-render pair rectangular engines repeat when placing one child at
    # a time (every `Border` region, `Form`'s trailing full-width child).
    # `Form`'s label/field pair deliberately does **not** use this: it places
    # both children before rendering either (so shared row height applies to
    # both), keeping `#place_child`/`#render_child` calls separate.
    protected def place_and_render(el : Widget, left : Int32, top : Int32, width : Int32, height : Int32) : Nil
      place_child el, left, top, width, height
      render_child el
    end

    # --- Layout-owned ("managed") size bookkeeping -------------------------
    #
    # `Border`, `Form` (and, in a Set-backed variant, `Box`) resolve a child's
    # raw size to cells and write the resolved `Int32` back through
    # `set_geometry`. That write would otherwise *destroy* the child's original
    # value — a `"50%"` string never resolves again (frozen at frame 1's cell
    # count), a `nil`/auto size freezes at that cell count, a transient clamp
    # sticks. Each engine therefore keeps a `raw_map` (the value the user set)
    # beside an `assigned_map` (the Int we last wrote), restoring the raw value
    # before re-measuring and releasing a child the moment its raw size no
    # longer equals what we assigned (the user reclaimed it). These helpers
    # single-source that shared core; the per-engine axis/field is supplied by
    # the caller (which maps, the raw getter, the restore setter). All three are
    # allocation-free: `prune_managed`'s `select!` block and `restore_managed`'s
    # restore block are `yield`ed, never captured as a stored `Proc`.

    # Drops bookkeeping entries for children that have left `container`. O(1)
    # membership via `Widget#child?`; in-place `select!`, so it allocates
    # nothing. Hash-shaped maps only (two-arg block); a `Set`-backed tracker
    # (e.g. `Box`'s `@flex`/`@filled`) prunes with a one-arg `select!` inline.
    protected def prune_managed(container : Widget, map) : Nil
      map.select! { |el, _| container.child? el }
    end

    # Restores `el`'s remembered raw size (passed in as `raw`) before a
    # re-measure — so a percent/nil/clamped size resolves against the *live*
    # container every frame — or, when the raw size no longer equals what we
    # last assigned, forgets the old value and records the new one (the user
    # reclaimed the child; cf. `Box#main_flex?`). The block receives the
    # remembered raw value and writes it back into the child's axis.
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
    def self.fence(total : Int32, n : Int32, i : Int32) : Int32
      i = i.clamp(0, n)
      (i * total) // n
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

    # Number of arrangeable (non-`layout_excluded?`, non-`layout_chrome?`)
    # children — the slot/page count engines size their distribution against.
    protected def arrangeable_count(container : Widget) : Int32
      container.children.count { |el| !el.layout_excluded? && !el.layout_chrome? }
    end

    # The container's interior content rectangle (inside border + padding), in
    # absolute window coordinates, or nil if collapsed to nothing.
    # `container.lpos` is already up to date by the time children render, so
    # this reads it directly rather than re-deriving coordinates.
    protected def interior_coords(container : Widget) : LPos?
      lpos = container.lpos
      return unless lpos
      xi = lpos.xi + container.ileft
      xl = lpos.xl - container.iright
      yi = lpos.yi + container.itop
      yl = lpos.yl - container.ibottom
      return if (xl - xi <= 0) || (yl - yi <= 0)
      i = @interior_lpos
      i.xi = xi
      i.xl = xl
      i.yi = yi
      i.yl = yl
      i
    end

    # `el`'s rendered rectangle from the last frame if non-empty, else nil. Lets
    # layout callers bind `lpos` directly instead of re-reading it through a
    # `not_nil!` after a separate `rendered?` check.
    @[AlwaysInline]
    protected def rendered_lpos(el : Widget) : LPos?
      return nil unless l = el.lpos
      ((l.xl - l.xi) > 0) && ((l.yl - l.yi) > 0) ? l : nil
    end

    # Whether `el` produced a non-empty rendered rectangle on the last frame.
    protected def rendered?(el : Widget) : Bool
      !rendered_lpos(el).nil?
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
    protected def get_last(container : Widget, i : Int32) : Widget?
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
