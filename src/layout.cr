module Crysterm
  # Base class for *child-arranging* layout engines.
  #
  # A layout is a strategy object installed on any container `Widget` via
  # `Widget#layout=`. It is deliberately **not** a widget (cf. Qt's `QLayout`,
  # which is not a `QWidget`): the container owns the on-screen rectangle, the
  # border, the padding and the z-order slot; the layout only decides where the
  # children go *inside* that rectangle.
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
  # fixed rectangle) is what lets the full range of layouts be expressed
  # uniformly:
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
  # Engines that need extra per-child data (a Border region, a Grid cell+span, a
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
    # read it off `Widget#layout_hint`. Kept as an open extension point so new
    # engines can carry their own hint type without touching this hierarchy.
    abstract class Hint
    end

    # Spacing between adjacent children, in cells (Qt's layout `spacing`, CSS
    # `spacing`). Lives on the base so it can be set uniformly — e.g. from CSS via
    # `Geometry.apply` — regardless of engine. The box/grid/form engines honor it;
    # the flow engines (`Masonry`/`Wrap`/`UniformGrid`) currently ignore it and
    # pack children at their natural spacing.
    property gap : Int32 = 0

    # Reused interior rectangle, mutated and returned by `#interior_coords` each
    # frame instead of allocating a fresh `LPos` per render (mirroring
    # `LPos#reset` on the widget render path). `#arrange` reads only its four
    # coordinates and never retains it past the call, and a layout instance
    # serves a single container, so one cached rectangle per layout is safe.
    @interior_lpos = LPos.new

    # Entry point invoked by `Widget#_render`. Computes the container's interior
    # content rectangle and, if non-empty, delegates to `#arrange`.
    def render_children(container : Widget) : Nil
      interior = interior_coords container
      return unless interior
      arrange container, interior
    end

    # Arranges (and renders) the container's children within `interior` (the
    # absolute interior rectangle from `#interior_coords`). Implementations set
    # each child's geometry and render it via `#render_child`, or `#skip` it.
    abstract def arrange(container : Widget, interior : LPos) : Nil

    # Renders one child, performing the same render-index bookkeeping the
    # default (no-layout) loop in `Widget#_render` does.
    protected def render_child(el : Widget) : Nil
      # Layout-excluded chrome (e.g. a `background-image` layer) is rendered
      # out-of-band from `Widget#_render`, never through the child pass.
      return if el.layout_excluded?
      bump_index el
      render_or_defer el
    end

    # Renders `el` inline, or — when it carries a `z_index` and we are not
    # already compositing a layer — defers it to its own plane (composited after
    # the base tree); while compositing a layer, nested layers flatten into the
    # enclosing plane, so it renders inline there. Split from `#render_child`
    # (which also bumps the render index) so the flow/stack engines, which bump
    # every child themselves, can still honor the z-index deferral.
    protected def render_or_defer(el : Widget) : Nil
      scr = el.screen
      if el.style.z_index && !scr.compositing_layers?
        scr.defer_layer el
      else
        el.render
      end
    end

    # Assigns the child its z-order/render index for this frame. Split out from
    # `#render_child` so flow engines can keep the index bookkeeping identical
    # to the old loop (every child consumes an index, even one later `#skip`ped)
    # while still controlling whether the child renders.
    protected def bump_index(el : Widget) : Nil
      if el.screen._ci != -1
        el.index = el.screen._ci
        el.screen._ci += 1
      end
    end

    # Marks `el` as not rendered this frame (clears its last position).
    protected def skip(el : Widget) : Nil
      el.lpos = nil
    end

    # Assigns `el`'s full rectangle (left/top/width/height) in one call — the
    # four-assignment geometry block the rectangular engines (`Border`, `Form`)
    # would otherwise repeat at every placement. Does not render; the caller
    # follows with `#render_child` (so engines that place several children before
    # rendering them — e.g. `Form`'s label/field pair — stay in control of order).
    protected def place_child(el : Widget, left : Int32, top : Int32, width : Int32, height : Int32) : Nil
      el.left = left
      el.top = top
      el.width = width
      el.height = height
    end

    # Yields each of the container's *arrangeable* children — the ones an engine
    # actually positions — skipping `layout_excluded?` chrome (e.g. a
    # `background-image` layer or an out-of-band scrollbar, which is rendered
    # separately from `Widget#_render` and carries its own full-interior `lpos`).
    # Every engine's placement loop performs this same skip: an excluded child
    # must not consume a gap, a `justify`/page slot, a grid cell, a form
    # label/field, a dock region, nor inflate a flow row — so it lives here once
    # instead of being re-coded (and re-explained) per engine. Block-yielding (no
    # captured `Proc`), so it allocates nothing per frame.
    protected def each_arrangeable(container : Widget, &) : Nil
      container.children.each do |el|
        next if el.layout_excluded?
        yield el
      end
    end

    # Number of arrangeable (non-`layout_excluded?`) children — the slot/page
    # count engines size their distribution against.
    protected def arrangeable_count(container : Widget) : Int32
      container.children.count { |el| !el.layout_excluded? }
    end

    # The container's interior content rectangle (inside border + padding), in
    # absolute screen coordinates, or nil if it has collapsed to nothing.
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

    # `el`'s rendered rectangle from the last frame if it was non-empty, else nil.
    # Lets layout callers bind the `lpos` directly instead of re-reading it through
    # a `not_nil!` after a separate `rendered?` check.
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
    # that collapsed to nothing on the last frame), or nil if none.
    #
    # Layout-excluded chrome is skipped too: a `background-image` layer is a
    # `layout_excluded?` child that is rendered out-of-band (so it carries a
    # full-interior `lpos`) and lives in `children` like any other. Without this
    # guard a flow child appended after such a layer would chain its left edge
    # off the layer's full-width rect instead of off the previous *flow* child —
    # mirroring the `layout_excluded?` skip every engine's placement loop already
    # performs.
    protected def get_last(container : Widget, i : Int32) : Widget?
      while i > 0
        i -= 1
        el = container.children[i]
        next if el.layout_excluded?
        return el if rendered? el
      end
      nil
    end
  end
end

# The abstract `Flow` strategy base subclasses `Layout`, so it is required after
# the base above is defined; its concrete engines (Masonry, UniformGrid, Wrap)
# live under `src/layout/`.
require "./layout_flow"
