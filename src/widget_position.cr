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
    getter left : Dim | Int32 | String?

    # User-defined top
    getter top : Dim | Int32 | String?

    # User-defined right
    getter right : Dim | Int32 | String?

    # User-defined bottom
    getter bottom : Dim | Int32 | String?

    # `left=`/`top=`/`right=`/`bottom=`: change-guarded setters that normalize
    # through `Dim.from` (parse-at-assignment), mark dirty and emit `Move`. The
    # assign lands *before* the emit so in-tree Move listeners see the new
    # position, not the old one (cf. `width=` for Resize).
    {% for side in %w[left top right bottom] %}
      # Sets Widget's `@{{ side.id }}`
      def {{ side.id }}=(val : Dim | Int32 | String | Symbol | Nil)
        val = Dim.from val
        return if @{{ side.id }} == val
        @{{ side.id }} = val
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
      # Returns computed relative {{ side.id }}
      def r{{ side.id }}
        (a{{ side.id }} || 0) - (parent_or_window.a{{ side.id }} || 0)
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

    # `aleft`/`atop`: computed absolute near-edge position, the mechanical axis
    # mirror of each other (left→top, right→bottom, awidth→aheight, ileft→itop).
    # Generated from one body — like the `aright`/`abottom` loop below and the
    # `rleft`/… loop above — so the subtle margin-anchor / center / parent-pos
    # threading can never drift between the two axes. The size parameter itself
    # is axis-specific (`width` on the x axis, `height` on the y axis), so its
    # name comes from `{{ axis[:dim].id }}` too; the signatures stay identical to
    # the hand-written originals.
    {% for axis in [
                     {near: "left", far: "right", dim: "width"},
                     {near: "top", far: "bottom", dim: "height"},
                   ] %}
      # Returns computed absolute {{ axis[:near].id }} position.
      #
      # `{{ axis[:dim].id }}`, when given, is this widget's already-resolved
      # `a{{ axis[:dim].id }}(rendered)`, needed by the far-anchored and `"center"`
      # branches; passing it in avoids a second `a{{ axis[:dim].id }}` walk per
      # frame. When nil it is resolved on demand.
      def a{{ axis[:near].id }}(rendered = false, {{ axis[:dim].id }} = nil, parent_pos = nil, with_margin = true) : Int32
        # Original {{ axis[:near].id }}
        o{{ axis[:near].id }} = @{{ axis[:near].id }}
        o{{ axis[:far].id }} = @{{ axis[:far].id }}

        mg = style.margin

        # Far-anchored: the outward margin pushes the box toward its NEAR edge by
        # its own far margin. Included so hit-test geometry matches where `coords`
        # paints it; `coords` and the anchoring callers below pass
        # `with_margin: false` so the shift is applied exactly once.
        if o{{ axis[:near].id }}.nil? && !o{{ axis[:far].id }}.nil?
          m_far = (with_margin && mg.any?) ? mg.{{ axis[:far].id }} : 0
          return window.a{{ axis[:dim].id }} - ({{ axis[:dim].id }} || a{{ axis[:dim].id }}(rendered)) - a{{ axis[:far].id }}(rendered) - m_far
        end

        # Near-anchored: the outward margin pushes the box toward its FAR edge by
        # its own near margin (see above for why it's gated on `with_margin`).
        m_near = (with_margin && mg.any?) ? mg.{{ axis[:near].id }} : 0

        # `parent_pos`, when given, is the parent's already-resolved position for
        # this frame, threaded in by `coords` so `aleft`/`atop` don't re-resolve.
        parent = parent_pos || (rendered ? parent_or_window.last_rendered_position : parent_or_window)

        {{ axis[:near].id }} = o{{ axis[:near].id }} || 0
        unless {{ axis[:near].id }}.is_a? Int32
          {{ axis[:near].id }} = resolve_dim({{ axis[:near].id }}, parent.a{{ axis[:dim].id }} || 0)
          if center_expr?(o{{ axis[:near].id }})
            {{ axis[:near].id }} -= ({{ axis[:dim].id }} || a{{ axis[:dim].id }}(rendered)) // 2
          end
        end

        if applies_near_offset?(o{{ axis[:near].id }}, o{{ axis[:far].id }})
          {{ axis[:near].id }} += parent.i{{ axis[:near].id }}
        end

        (parent.a{{ axis[:near].id }} || 0) + {{ axis[:near].id }} + m_near
      end
    {% end %}

    # `aright`/`abottom`: computed absolute far-edge position, the mechanical
    # axis mirror of each other (left→top, right→bottom, awidth→aheight,
    # iright→ibottom). Generated from one body so a fix to one axis can never
    # drift from the other — see the `rleft`/`rtop`/… loop above for the same
    # pattern. Each axis map lists exactly the tokens that differ: `near`/`far`
    # edge names and `dim` (the same-axis size word, `width`/`height`).
    {% for axis in [
                     {near: "left", far: "right", dim: "width"},
                     {near: "top", far: "bottom", dim: "height"},
                   ] %}
      # Returns computed absolute {{ axis[:far].id }} position
      def a{{ axis[:far].id }}(rendered = false) : Int32
        o{{ axis[:near].id }} = @{{ axis[:near].id }}
        o{{ axis[:far].id }} = @{{ axis[:far].id }}

        parent = rendered ? parent_or_window.last_rendered_position : parent_or_window

        if o{{ axis[:far].id }}.nil? && !o{{ axis[:near].id }}.nil?
          # Base geometry: `coords` composes in the margin, so this far-edge
          # offset must not double-count it.
          {{ axis[:far].id }} = window.a{{ axis[:dim].id }} - (a{{ axis[:near].id }}(rendered, with_margin: false) + a{{ axis[:dim].id }}(rendered))
          {{ axis[:far].id }} += parent.i{{ axis[:far].id }}
          return {{ axis[:far].id }}
        end

        # A `Dim` far edge (`"50%"`) resolves against the parent's {{ axis[:dim].id }},
        # exactly as a `Dim` near edge does in `#a{{ axis[:near].id }}`. Kept behind the
        # type test so the common `Int32`/`nil` case never triggers the
        # `parent.a{{ axis[:dim].id }}` ancestor walk.
        {{ axis[:far].id }} = case o{{ axis[:far].id }}
                              in Int32       then o{{ axis[:far].id }}
                              in Dim, String then resolve_dim(o{{ axis[:far].id }}, parent.a{{ axis[:dim].id }} || 0)
                              in Nil         then 0
                              end
        {{ axis[:far].id }} += (parent.a{{ axis[:far].id }} || 0)
        {{ axis[:far].id }} += parent.i{{ axis[:far].id }}

        {{ axis[:far].id }}
      end
    {% end %}

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
      # Saturating, not checked: a pathological (e.g. `Int32::MAX`) fixed
      # width/height combined with a nonzero absolute origin overflows plain
      # `Int32 + Int32` here and raises `OverflowError` in the render fiber
      # (B18-25) — an origin-0 widget with the same size happens to land
      # exactly on `Int32::MAX` and doesn't overflow, which is what let this
      # slip through as "renders fine". Clamping the far edge instead is
      # behavior-preserving: downstream clipping already tolerates
      # `xl == Int32::MAX` today.
      xl = (xi.to_i64 + w).clamp(Int32::MIN.to_i64, Int32::MAX.to_i64).to_i32
      yi = atop(rendered, h, ppos, with_margin: false)
      yl = (yi.to_i64 + h).clamp(Int32::MIN.to_i64, Int32::MAX.to_i64).to_i32

      # Which side is partly hidden due to being enclosed in a parent
      # (potentially scrollable) element. Set/computed later.
      no_left = false
      no_top = false
      no_right = false
      no_bottom = false

      # How many rows/columns each clipped edge lost to the clipping ancestor's
      # viewport (see `RenderedGeometry#hidden_top` & co).
      hidden_left = 0
      hidden_top = 0
      hidden_right = 0
      hidden_bottom = 0

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
        my_padding = style.padding
        sp_border = scrollable_parent.style.border

        # The clip on each edge must trigger at THAT edge's inner (border) width:
        # the bottom clip against the parent's BOTTOM border, the horizontal clips
        # against the LEFT/RIGHT ones. Reusing `b` (the top border) for all edges
        # mis-clips asymmetric borders. Each width is the *visible* remainder of
        # the parent's own border band: when the parent is itself clipped by ITS
        # ancestor, the hidden part of its band (`hidden_*` on the parent's lpos)
        # no longer insets the viewport — a fully clipped-away parent border
        # means the parent's inner edge IS its lpos edge.
        b = effective_edge_insets(sp_border.top, 0, scrollable_parent_lpos.hidden_top)[0]
        bb = effective_edge_insets(sp_border.bottom, 0, scrollable_parent_lpos.hidden_bottom)[0]
        bl = effective_edge_insets(sp_border.left, 0, scrollable_parent_lpos.hidden_left)[0]
        br = effective_edge_insets(sp_border.right, 0, scrollable_parent_lpos.hidden_right)[0]

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
            # Is partially covered above. `v` is the number of this widget's own
            # rows hidden above the clip edge (the parent's inner top): clamp
            # `yi` to that edge — never past it, so `lpos` (hit-testing,
            # tint/shadow, dock stops) stays inside the ancestor's viewport —
            # and advance `base` by the hidden CONTENT lines only. The widget's
            # own top border and padding rows are not content lines, and when
            # fewer rows than `border.top + padding.top` are hidden, no content
            # is hidden at all — the floor keeps `base` from going negative
            # (a negative index silently wraps `Array#[]?` around to the LAST
            # content line). `base_render` derives the still-visible part of
            # the border/padding bands from `hidden_top`.
            no_top = true
            v = (scrollable_parent_lpos.yi + b) - yi
            hidden_top = v
            base += Math.max(v - my_border.top - my_padding.top, 0)
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
            # Is partially covered below: clamp `yl` to the parent's inner
            # bottom. Widening the rect by this widget's own border thickness
            # instead (the pre-clamp behavior) leaked `lpos` past the viewport:
            # clicks/hover, `style.tint`/shadow bands and dock-stop rows all
            # landed on cells outside the container.
            no_bottom = true
            v = yl - (scrollable_parent_lpos.yl - bb)
            hidden_bottom = v
            yl -= v
          end
        end

        if yi >= yl
          return
        end

        # Could allow overlapping stuff in scrolling elements
        # if we cleared the pending buffer before every draw.
        #
        # Horizontal clips clamp to the parent's inner edges the same way the
        # vertical ones do (see the bottom clip above for why no widening by
        # this widget's own border happens here). There is no horizontal `base`:
        # content columns are not index-shifted, so only the hidden count is
        # recorded.
        if xi < scrollable_parent_lpos.xi + bl
          no_left = true
          hidden_left = (scrollable_parent_lpos.xi + bl) - xi
          xi = scrollable_parent_lpos.xi + bl
        end
        if xl > scrollable_parent_lpos.xl - br
          no_right = true
          hidden_right = xl - (scrollable_parent_lpos.xl - br)
          xl = scrollable_parent_lpos.xl - br
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
      if overflow.move_widget?
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
          renders: window.renders,
          hidden_left: hidden_left,
          hidden_right: hidden_right,
          hidden_top: hidden_top,
          hidden_bottom: hidden_bottom
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
          renders: window.renders,
          hidden_left: hidden_left,
          hidden_right: hidden_right,
          hidden_top: hidden_top,
          hidden_bottom: hidden_bottom
      end
      v
    end

    # The widget's *painted* outer rect `{x, y, w, h}` from
    # `last_rendered_position?`, falling back to the layout coords
    # (`aleft`/`atop`/`awidth`/`aheight`) before the first render (or when the
    # widget resolved to nothing last frame). Popup owners must anchor on this,
    # not on layout coords: inside a scrolled/child_base ancestor the two
    # diverge by the ancestor's scroll base, and a window-child popup is
    # painted exactly where it is placed — so layout coords would open it
    # detached from the visible widget. Mirrors ComboBox#place_popup /
    # DateEdit#position_popup / Menu#open_submenu.
    def painted_rect : {Int32, Int32, Int32, Int32}
      if lp = last_rendered_position?
        {lp.xi, lp.yi, lp.xl - lp.xi, lp.yl - lp.yi}
      else
        {aleft, atop, awidth, aheight}
      end
    end
  end
end
