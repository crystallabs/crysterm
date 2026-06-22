module Crysterm
  # Base class for *child-arranging* layout engines.
  #
  # A layout is a strategy object installed on any container `Widget` via
  # `Widget#layout=`. It is deliberately **not** a widget (cf. Qt's `QLayout`,
  # which is not a `QWidget`): the container owns the on-screen rectangle, the
  # border, the padding and the z-order slot; the layout only decides where the
  # children go *inside* that rectangle.
  #
  # During the container's render, once the container has drawn itself and its
  # `#lpos` is known, `Widget#_render` hands the children to the installed
  # layout via `#render_children`. The default implementation walks the
  # children, asks `#place` to position each one (honoring its returned
  # `Overflow` action), and renders it — exactly mirroring the per-child index
  # bookkeeping and overflow handling that `Widget#_render` performs for the
  # no-layout (manual positioning) case.
  #
  # Concrete child-arranging engines:
  # * `Layout::Masonry` — masonry/inline flow (blessed's `inline`).
  # * `Layout::Grid`    — uniform grid (blessed's `grid`).
  # * `Layout::HBox` / `Layout::VBox` — Qt-style single-axis boxes.
  #
  # Table widgets (`Widget::Table`, `Widget::ListTable`) instead use the
  # separate *content* layout `TableLayout`: they lay out cell text inside their
  # own content rather than arranging child widgets, so they mix in behavior
  # rather than installing a child-arranging engine here.
  abstract class Layout
    # Arranges and renders `container`'s children. Computes the interior
    # rectangle once, runs the optional `#before_children` pre-pass, then for
    # each child performs the same render-index bookkeeping as the plain loop in
    # `Widget#_render`, asks `#place` to position it, and renders it (unless the
    # returned `Overflow` says to skip/stop).
    def render_children(container : Widget) : Nil
      interior = interior_coords container
      return unless interior

      before_children container, interior

      container.children.each_with_index do |el, i|
        if el.screen._ci != -1
          el.index = el.screen._ci
          el.screen._ci += 1
        end

        case place container, el, i, interior
        when Overflow::SkipWidget
          el.lpos = nil
          next
        when Overflow::StopRendering
          el.lpos = nil
          break
        when Overflow::MoveWidget
          raise Exception.new "Layout overflow MoveWidget is not implemented yet"
        end

        el.render
      end
    end

    # Positions `el` (the `i`-th child) within `interior` by setting its
    # `left`/`top` (and, for sizing layouts, `width`/`height`). Returns an
    # `Overflow` action when the child does not fit, or `nil` to render it.
    # `interior` is the absolute interior rectangle from `#interior_coords`.
    abstract def place(container : Widget, el : Widget, i : Int32, interior : LPos) : Overflow?

    # Optional per-render pre-pass, run after the interior is known but before
    # any child is placed (e.g. to measure flexible tracks). Default: no-op.
    def before_children(container : Widget, interior : LPos) : Nil
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
      LPos.new xi: xi, xl: xl, yi: yi, yl: yl
    end

    # Whether `el` produced a non-empty rendered rectangle on the last frame.
    protected def rendered?(el : Widget) : Bool
      return false unless l = el.lpos
      ((l.xl - l.xi) > 0) && ((l.yl - l.yi) > 0)
    end

    # The most recently *rendered* child before index `i` (skipping children
    # that collapsed to nothing on the last frame), or nil if none.
    protected def get_last(container : Widget, i : Int32) : Widget?
      while i > 0
        i -= 1
        el = container.children[i]
        return el if rendered? el
      end
      nil
    end
  end
end
