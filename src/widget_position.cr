require "./macros"
require "./dim"

module Crysterm
  class Widget
    include Macros

    # Methods related to 2D position (X and Y).
    # Position in 3D (index) is in widget_children.cr

    # The four edge offsets, exactly as the user set them — not computed. `nil`
    # means "unanchored on this edge"; see `#aleft` and friends for the resolved
    # values.
    #
    # All four accept a cell count (`Int32`), a `Dim` (`Dim.percent(50, 5)`,
    # `Dim.center`), `:center`, or the string micro-DSL (`"50%"`, `"50%+5"`,
    # `"center-3"`, `"50vw"`) — strings/symbols are parsed to a `Dim` **once,
    # at assignment** (a malformed string raises `ArgumentError` there, rather
    # than silently resolving to 0 every frame). All four resolve through the
    # same path: `right: "50%"` works exactly like `left: "50%"`.

    # User-defined left
    getter left : Dim | Int32 | String | Nil

    # User-defined top
    getter top : Dim | Int32 | String | Nil

    # User-defined right
    getter right : Dim | Int32 | String | Nil

    # User-defined bottom
    getter bottom : Dim | Int32 | String | Nil

    # `left=`/`top=`/`right=`/`bottom=`: change-guarded setters that normalize
    # through `Dim.from` (parse-at-assignment), mark dirty and emit `Move`. The
    # assign lands *before* the emit so in-tree Move listeners see the new
    # position, not the old one (cf. `width=` for Resize).
    {% for side in %w[left top right bottom] %}
      # Sets Widget's `@{{side.id}}`
      def {{side.id}}=(val : Dim | Int32 | String | Symbol | Nil)
        val = Dim.from val
        return if @{{side.id}} == val
        @{{side.id}} = val
        mark_dirty
        emit ::Crysterm::Event::Move
      end
    {% end %}

    #
    # Computed relative position on window
    #

    # `rleft`/`rtop`/`rright`/`rbottom`: computed relative position, mechanically
    # identical across the four sides modulo which `a*` getter they call.
    {% for side in %w(left top right bottom) %}
      # Returns computed relative {{side.id}}
      def r{{side.id}}
        (a{{side.id}} || 0) - (parent_or_window.a{{side.id}} || 0)
      end
    {% end %}

    # `#rleft` under Qt's `QWidget::x()` name.
    def x : Int32
      rleft
    end

    # `#rtop` under Qt's `QWidget::y()` name.
    def y : Int32
      rtop
    end

    # `#lpos` (from `Mixin::Pos`) under Qt's `QWidget::geometry()`-adjacent
    # vocabulary — the widget's last rendered box. Same object every frame (see
    # `RenderedGeometry`); read it, don't retain it past the current frame.
    def rendered_geometry : RenderedGeometry?
      lpos
    end

    #
    # Computed absolute position on window
    #

    # Resolves a stored `Dim` against the parent extent *against*, in cells; a
    # viewport kind resolves against the live window size instead.
    private def resolve_dim(o : Dim, against : Int32) : Int32
      if o.viewport?
        scr = window
        o.resolve_viewport scr.awidth, scr.aheight
      else
        o.resolve against
      end
    end

    # Cold arm for a raw `String` written directly into a geometry ivar
    # (bypassing the normalizing setters): parsed per frame, with a malformed
    # expression degrading to the historical 0 — a frame must never raise.
    # *size* selects the `"half"` alias over `"center"`.
    private def resolve_dim(o : String, against : Int32, size : Bool = false) : Int32
      (d = Dim.parse?(o, size: size)) ? resolve_dim(d, against) : 0
    end

    # Resolves a raw edge value (`@left`/`@top`/`@right`/`@bottom`) to cells: an
    # `Int32` passes through, `nil` reads as 0, and a `Dim` (or cold `String`)
    # resolves against *parent_dim*. Callers that only have `parent_dim` behind
    # an ancestor walk must keep the non-`Int32` test outside this helper, so
    # the common `Int32` case doesn't pay for the walk.
    private def resolve_edge(o, parent_dim : Int32) : Int32
      case o
      when Dim, String then resolve_dim(o, parent_dim)
      when Int32       then o
      else                  0
      end
    end

    # Whether a position value asks to be centered — `Dim.center` (or the cold
    # raw-string spelling; see `#resolve_dim`). Centered widgets pull back by
    # half their size and skip the near-side inner offset.
    private def center_expr?(o) : Bool
      case o
      when Dim    then o.center?
      when String then o == "center" || o.starts_with?("center+") || o.starts_with?("center-")
      else             false
      end
    end

    # Whether the parent's near-side inner offset (`ileft`/`itop`) applies to a
    # widget whose primary edge is `o` and opposite edge is `o_opp`. The actual
    # `+=`/`-=` stays at each call site since it differs by axis/direction.
    private def applies_near_offset?(o, o_opp) : Bool
      (!o.nil? || o_opp.nil?) && !center_expr?(o)
    end

    # Returns computed absolute left position.
    #
    # `width`, when given, is this widget's already-resolved `awidth(rendered)`,
    # needed by the right-anchored and `"center"` branches; passing it in avoids a
    # second `awidth` walk per frame. When nil it is resolved on demand.
    def aleft(rendered = false, width = nil, parent_pos = nil, with_margin = true) : Int32
      # Original left
      oleft = @left
      oright = @right

      mg = style.margin

      # Right-anchored: the outward margin pushes the box LEFT by its own right
      # margin. Included so hit-test geometry matches where `coords` paints it;
      # `coords` and the anchoring callers below pass `with_margin: false` so the
      # shift is applied exactly once.
      if oleft.nil? && !oright.nil?
        mr = (with_margin && mg.any?) ? mg.right : 0
        return window.awidth - (width || awidth(rendered)) - aright(rendered) - mr
      end

      # Left-anchored: the outward margin pushes the box RIGHT by its own left
      # margin (see above for why it's gated on `with_margin`).
      ml = (with_margin && mg.any?) ? mg.left : 0

      # `parent_pos`, when given, is the parent's already-resolved position for
      # this frame, threaded in by `coords` so `aleft`/`atop` don't re-resolve.
      parent = parent_pos || (rendered ? parent_or_window.last_rendered_position : parent_or_window)

      left = oleft || 0
      unless left.is_a? Int32
        left = resolve_dim(left, parent.awidth || 0)
        if center_expr?(oleft)
          left -= (width || awidth(rendered)) // 2
        end
      end

      if applies_near_offset?(oleft, oright)
        left += parent.ileft
      end

      (parent.aleft || 0) + left + ml
    end

    # Returns computed absolute top position. `height`, when given, is this
    # widget's already-resolved `aheight(rendered)` — see `#aleft`.
    def atop(rendered = false, height = nil, parent_pos = nil, with_margin = true) : Int32
      otop = @top
      obottom = @bottom

      mg = style.margin

      # See `#aleft`: bottom-anchored, the outward margin pushes the box UP by
      # its own bottom margin.
      if otop.nil? && !obottom.nil?
        mb = (with_margin && mg.any?) ? mg.bottom : 0
        return window.aheight - (height || aheight(rendered)) - abottom(rendered) - mb
      end

      # See `#aleft`: top-anchored, the outward margin pushes the box DOWN by its
      # own top margin.
      mt = (with_margin && mg.any?) ? mg.top : 0

      # See `#aleft`: `parent_pos` is the parent's already-resolved position.
      parent = parent_pos || (rendered ? parent_or_window.last_rendered_position : parent_or_window)

      top = otop || 0
      unless top.is_a? Int32
        top = resolve_dim(top, parent.aheight || 0)
        if center_expr?(otop)
          top -= (height || aheight(rendered)) // 2
        end
      end

      if applies_near_offset?(otop, obottom)
        top += parent.itop
      end

      (parent.atop || 0) + top + mt
    end

    # Returns computed absolute right position
    def aright(rendered = false) : Int32
      oleft = @left
      oright = @right

      parent = rendered ? parent_or_window.last_rendered_position : parent_or_window

      if oright.nil? && !oleft.nil?
        # Base geometry: `coords` composes in the margin, so this far-edge
        # offset must not double-count it.
        right = window.awidth - (aleft(rendered, with_margin: false) + awidth(rendered))
        right += parent.iright
        return right
      end

      # A `Dim` right (`"50%"`) resolves against the parent's width, exactly as
      # a `Dim` left does in `#aleft`. Kept behind the type test so the common
      # `Int32`/`nil` case never triggers the `parent.awidth` ancestor walk.
      right = case oright
              in Int32       then oright
              in Dim, String then resolve_dim(oright, parent.awidth || 0)
              in Nil         then 0
              end
      right += (parent.aright || 0)
      right += parent.iright

      right
    end

    # Returns computed absolute bottom position
    def abottom(rendered = false) : Int32
      otop = @top
      obottom = @bottom

      parent = rendered ? parent_or_window.last_rendered_position : parent_or_window

      if obottom.nil? && !otop.nil?
        # Base geometry (see `#aright`): margin is composed in by `coords`.
        bottom = window.aheight - atop(rendered, with_margin: false) - aheight(rendered)
        bottom += parent.ibottom
        return bottom
      end

      # See `#aright`: a `Dim` bottom resolves against the parent's height,
      # with the ancestor walk kept off the `Int32`/`nil` fast path.
      bottom = case obottom
               in Int32       then obottom
               in Dim, String then resolve_dim(obottom, parent.aheight || 0)
               in Nil         then 0
               end
      bottom += (parent.abottom || 0)
      bottom += parent.ibottom

      bottom
    end

    # Shifts the `lo..hi` pair by the widget's own margin: outward by `far` when
    # only the far side is anchored (`near_anchor` nil, `far_anchor` not),
    # otherwise outward by `near`. `near_anchor`/`far_anchor` are the raw
    # `@left`/`@right` (or `@top`/`@bottom`) values. An unconditional shift, not a
    # bounds clamp — unlike `translate_into_bounds` below.
    private def shift_margin(lo : Int32, hi : Int32, near_anchor, far_anchor, near : Int32, far : Int32) : {Int32, Int32}
      if near_anchor.nil? && !far_anchor.nil?
        {lo - far, hi - far}
      else
        {lo + near, hi + near}
      end
    end

    # Clamps `lo` up to at least `min` and `hi` down to at most `max`,
    # independently: a widget's edges never cross past its `ShrinkWidget` parent's
    # inner rectangle.
    private def clamp_edge_pair(lo : Int32, hi : Int32, min : Int32, max : Int32) : {Int32, Int32}
      lo = min if lo < min
      hi = max if hi > max
      {lo, hi}
    end

    # Translates the `lo..hi` pair (preserving its width) so it fits within
    # `min..max`: pulls in from the far edge first, then the near edge, so a span
    # wider than `max - min` ends up anchored at `min` with overflow on the far
    # side.
    private def translate_into_bounds(lo : Int32, hi : Int32, min : Int32, max : Int32) : {Int32, Int32}
      if hi > max
        d = hi - max
        lo -= d
        hi -= d
      end
      if lo < min
        d = min - lo
        lo += d
        hi += d
      end
      {lo, hi}
    end

    # `width_hint`, when given, is this widget's already-resolved `awidth(rendered)`,
    # computed by `#base_render` just before calling here, to skip re-resolving the
    # identical `awidth`. Only the render path passes it.
    # ameba:disable Metrics/CyclomaticComplexity
    def coords(rendered = false, noscroll = false, into : RenderedGeometry? = nil, width_hint : Int32? = nil) : RenderedGeometry?
      unless style.visible?
        return
      end

      # Resolve the parent (or window) and its rendered position once for the
      # whole coordinate pass, threaded through instead of `aleft`/`atop` and
      # the clip/shrink section each re-resolving it.
      por = parent_or_window
      ppos = rendered ? por.last_rendered_position : por

      # Resolve each dimension once, reused for both the anchored origin
      # (`aleft`/`atop`) and the far edge (`xl`/`yl`), so a right-anchored or
      # `"center"` widget doesn't walk `awidth`/`aheight` twice per frame.
      # `awidth`/`aheight` give the border-box size (an auto width already folds in
      # the margin; a fixed one does not); the margin block below only *shifts*
      # this box, and the origin getters take `with_margin: false` so the shift is
      # applied here exactly once.
      w = width_hint || awidth(rendered)
      h = aheight(rendered)
      xi = aleft(rendered, w, ppos, with_margin: false)
      xl = xi + w
      yi = atop(rendered, h, ppos, with_margin: false)
      yl = yi + h

      # Which side is partly hidden due to being enclosed in a parent
      # (potentially scrollable) element. Set/computed later.
      no_left = false
      no_top = false
      no_right = false
      no_bottom = false

      base = @child_base
      el = self
      fixed = @fixed

      # Attempt to resize the element based on the
      # size of the content and child elements.
      if shrink_to_fit?
        coords = minimal_rectangle(xi, xl, yi, yl, rendered)
        xi = coords.xi
        xl = coords.xl
        yi = coords.yi
        yl = coords.yl

        # Re-apply the `[min, max]` size constraints: `awidth`/`aheight` clamp the
        # pre-shrink size, but the content/children-derived rectangle replaces it
        # wholesale, bypassing them. The clamp must respect the anchored edge — a
        # right/bottom-anchored shrink keeps its far edge and grew toward the near
        # one, so the correction moves `xi`/`yi`; every other anchoring moves the
        # far edge. Guarded on `!=` so an unconstrained axis is untouched, and
        # floored at 0 so a pathological constraint can't invert the rectangle.
        sw = xl - xi
        cw = clamp_awidth(sw)
        if cw != sw
          cw = 0 if cw < 0
          if @left.nil? && !@right.nil?
            xi = xl - cw
          else
            xl = xi + cw
          end
        end
        sh = yl - yi
        ch = clamp_aheight(sh)
        if ch != sh
          ch = 0 if ch < 0
          if @top.nil? && !@bottom.nil?
            yi = yl - ch
          else
            yl = yi + ch
          end
        end
      end

      # Apply the element's own margin, CSS-style (*outward*): the border box keeps
      # its size and is pushed away from its anchored edge by the near margin, so
      # the margin reserves space *outside* the box rather than eating into it. A
      # stretched auto size already folded its margin into `awidth`/`aheight`, so
      # shifting is all that remains; a fixed size never shrinks.
      if (margin = style.margin).any?
        xi, xl = shift_margin(xi, xl, @left, @right, margin.left, margin.right)
        yi, yl = shift_margin(yi, yl, @top, @bottom, margin.top, margin.bottom)
      end

      # Find the nearest ancestor that clips its children: a scrollable element
      # (clips to its scroll viewport) or one with `overflow: Hidden` (clips to
      # its rectangle without scrolling). A Hidden, non-scrollable parent has
      # `child_base == 0`, so the scroll-offset math degenerates to a plain clip.
      while el = el.parent
        if el.scrollable? || el.overflow.hidden?
          # `fixed` widgets (e.g. labels on a border) are exempt from scroll
          # clipping, but not from `overflow: Hidden` clipping.
          if fixed && el.scrollable?
            fixed = false
            next
          end
          break
        end
      end

      # Check that we're visible and inside the visible scroll area.
      # Note: Lists have a property where only the list items are obfuscated.

      # First/closest clipping parent: scrollable, or `overflow: Hidden`. For a
      # Hidden parent the scroll-specific terms (`.base`) are simply zero.
      scrollable_parent = el

      # Using scrollable_parent && el here to restrict both to non-nil
      if scrollable_parent && !noscroll
        # This is an intentional assignment:
        unless scrollable_parent_lpos = scrollable_parent.lpos
          # The scrollable ancestor has no `lpos` yet (computed only during
          # rendering) — coordinates requested before first render, e.g. via
          # `set_content`/`set_item`/`insert_item`. Return nil, same as for
          # invisible widgets.
          return
        end

        # O: TODO Figure out how to fix base (and cbase) to only
        # take into account the *parent's* padding.
        yi -= scrollable_parent_lpos.base
        yl -= scrollable_parent_lpos.base

        # `style.border` is always non-nil (zero border means "no border"; see
        # Style#border), so fetch both borders once.
        my_border = style.border
        sp_border = scrollable_parent.style.border

        b = sp_border.top
        # The clip on each edge must trigger at THAT edge's inner (border) width:
        # the bottom clip against the parent's BOTTOM border, the horizontal clips
        # against the LEFT/RIGHT ones. Reusing `b` (the top border) for all edges
        # mis-clips asymmetric borders.
        bb = sp_border.bottom
        bl = sp_border.left
        br = sp_border.right

        # Exempt a widget that *is* a label (it sits ON the parent's border) from
        # border compensation. Testing `@label_widget` instead ("widget HAS a label") is
        # the wrong direction: it would clip labels out of scrollable widgets and
        # zero all four compensations for any labeled child in a scrolled
        # container.
        if _is_label?
          b = 0
          bb = 0
          bl = 0
          br = 0
        end

        if yi < scrollable_parent_lpos.yi + b
          if yl - 1 < scrollable_parent_lpos.yi + b
            # Is above.
            return
          else
            # Is partially covered above.
            no_top = true
            v = scrollable_parent_lpos.yi - yi
            v -= my_border.top
            v += sp_border.top
            base += v
            yi += v
          end
        end

        # Separate `if` (not `elsif`): a widget at least as tall as the parent's
        # visible region overflows both top and bottom at once. An `elsif` would
        # let a top-clipped widget skip the bottom clip and leak past it.
        # Horizontal clipping below uses two `if`s too.
        if yl > scrollable_parent_lpos.yl - bb
          if yi > scrollable_parent_lpos.yl - 1 - bb
            # Is below.
            return
          else
            # Is partially covered below.
            no_bottom = true
            v = yl - scrollable_parent_lpos.yl
            v -= my_border.bottom
            v += sp_border.bottom
            yl -= v
          end
        end

        if yi >= yl
          return
        end

        # Could allow overlapping stuff in scrolling elements
        # if we cleared the pending buffer before every draw.
        if xi < scrollable_parent_lpos.xi + bl
          xi = scrollable_parent_lpos.xi
          no_left = true
          xi -= my_border.left
          xi += sp_border.left
        end
        if xl > scrollable_parent_lpos.xl - br
          xl = scrollable_parent_lpos.xl
          no_right = true
          xl += my_border.right
          xl -= sp_border.right
        end
        if xi >= xl
          return
        end
      end

      parent = por

      # NOTE `plp=parent.lpos` assignment below-right is intentional:
      if (parent.overflow == Overflow::ShrinkWidget) && (plp = parent.lpos)
        xi, xl = clamp_edge_pair(xi, xl, plp.xi + parent.ileft, plp.xl - parent.iright)
        yi, yl = clamp_edge_pair(yi, yl, plp.yi + parent.itop, plp.yl - parent.ibottom)
      end

      # `MoveWidget`: translate the whole rectangle to fit the window's visible
      # area, preserving size (e.g. a completion list that would run off the bottom
      # slides up to stay on window). Unlike `ShrinkWidget` (parent-policy, clamps
      # edges), this is child-policy: the widget declares it for itself.
      if self.overflow.move_widget?
        scr = window
        s_left = scr.ileft
        s_top = scr.itop
        s_right = scr.awidth - scr.iright
        s_bottom = scr.aheight - scr.ibottom

        xi, xl = translate_into_bounds(xi, xl, s_left, s_right)
        yi, yl = translate_into_bounds(yi, yl, s_top, s_bottom)
      end

      # Reuse the widget's existing `RenderedGeometry` when the caller offers one
      # (the render hot path passes `@lpos`), turning a per-frame heap allocation
      # into an in-place update. All early returns above precede this, so `into`
      # is never mutated on a path that yields no coords.
      if v = into
        v.reset \
          xi: xi,
          xl: xl,
          yi: yi,
          yl: yl,
          base: base,
          no_left: no_left,
          no_right: no_right,
          no_top: no_top,
          no_bottom: no_bottom,
          renders: window.renders
      else
        v = RenderedGeometry.new \
          xi: xi,
          xl: xl,
          yi: yi,
          yl: yl,
          base: base,
          no_left: no_left,
          no_right: no_right,
          no_top: no_top,
          no_bottom: no_bottom,
          renders: window.renders
      end
      v
    end
  end
end
