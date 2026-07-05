module Crysterm
  class Widget
    # Methods related to 2D position (X and Y).
    # Position in 3D (index) is in widget_children.cr

    # Resolves a percentage position/size expression against the parent
    # dimension `dim`. Accepts `"50%"`, `"50%+5"`, `"50%-3"` (callers pre-map
    # `"center"`/`"half"` to `"50%"`); returns `(dim * pct).to_i + offset`.
    # Allocation-free: byte-scans for the `+`/`-` separator, parses the offset
    # in place, and only materializes the percentage number (so `"33.5%"`
    # decimals still work). Pure, so it is unit-tested directly.
    def self.dimension(expr : String, dim : Int32) : Int32
      bytes = expr.to_slice

      # Find the offset separator (`+`/`-`); never at index 0 for valid input,
      # and the preceding byte is the trailing `%` of the percentage.
      sep = -1
      i = 1
      while i < bytes.size
        b = bytes.unsafe_fetch(i)
        if b == '+'.ord || b == '-'.ord
          sep = i
          break
        end
        i += 1
      end

      pct_end = sep == -1 ? bytes.size - 1 : sep - 1 # index of the '%'
      # Parse the percentage number in place (optional sign, digits, one dot) —
      # `byte_slice(...).to_f?` heap-allocated a String per call, and this runs
      # for every string-positioned widget every frame. A non-clean percentage
      # (e.g. `0.5em` -> `0.5e`) yields 0 rather than raising — last-line guard
      # so layout never aborts.
      k = 0
      neg_pct = false
      if pct_end > 0
        b0 = bytes.unsafe_fetch(0)
        if b0 == '-'.ord
          neg_pct = true
          k = 1
        elsif b0 == '+'.ord
          k = 1
        end
      end
      num = 0.0
      scale = 0.0         # 0 while in the integer part, then the next fraction digit's weight
      valid = pct_end > k # an empty number (or bare sign) is invalid -> 0
      while k < pct_end
        b = bytes.unsafe_fetch(k)
        if b == '.'.ord && scale == 0.0
          scale = 0.1
        elsif '0'.ord <= b <= '9'.ord
          d = (b - '0'.ord).to_f64
          if scale == 0.0
            num = num * 10 + d
          else
            num += d * scale
            scale /= 10
          end
        else
          valid = false
          break
        end
        k += 1
      end
      num = -num if neg_pct
      pct = valid ? num / 100 : 0.0

      off = 0
      if sep != -1
        neg = bytes.unsafe_fetch(sep) == '-'.ord
        j = sep + 1
        while j < bytes.size
          off = off * 10 + (bytes.unsafe_fetch(j).to_i - '0'.ord)
          j += 1
        end
        off = -off if neg
      end

      (dim * pct).to_i + off
    end

    #
    # Left/top/right/bottom getters and setters: exactly what the user set, not
    # computed (equivalent of `widget.position` in blessed).
    #

    # User-defined left
    getter left : Int32 | String | Nil

    # User-defined top
    getter top : Int32 | String | Nil

    # User-defined right
    getter right : Int32 | Nil

    # User-defined bottom
    getter bottom : Int32 | Nil

    # Sets Widget's `@left`
    def left=(val)
      return if @left == val
      # Assign (and mark dirty) *before* emitting so in-tree Move listeners see
      # the new position, not the old one (cf. `width=` for the Resize case).
      @left = val
      mark_dirty
      emit ::Crysterm::Event::Move
    end

    # Sets Widget's `@top`
    def top=(val)
      return if @top == val
      # See `left=`: assign before emit so listeners see the new position.
      @top = val
      mark_dirty
      emit ::Crysterm::Event::Move
    end

    # Sets Widget's `@right`
    def right=(val)
      return if @right == val
      # See `left=`: assign before emit so listeners see the new position.
      @right = val
      mark_dirty
      emit ::Crysterm::Event::Move
    end

    # Sets Widget's `@bottom`
    def bottom=(val)
      return if @bottom == val
      # See `left=`: assign before emit so listeners see the new position.
      @bottom = val
      mark_dirty
      emit ::Crysterm::Event::Move
    end

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

    #
    # Computed absolute position on window
    #

    # Resolves a `String` position/size expression to an absolute cell count
    # against `parent_dim`, first mapping the *aliased* word ("center" for
    # positions, "half" for sizes) to "50%". Shared by `aleft`/`atop`/`awidth`/
    # `aheight`; `aliased` is passed (rather than mapping both words) so an
    # unusual input like `width: "center"` keeps its original meaning.
    private def resolve_dimension(expr : String, parent_dim : Int32, aliased : String) : Int32
      # Viewport units resolve against the window every frame (`width: 50vw`
      # re-sizes on terminal resize): `vw`→width, `vh`→height, `vmin`/`vmax`→
      # smaller/larger side, like CSS. The `'v'` check is an allocation-free
      # gate keeping the heavier regex off the per-frame hot path.
      # `viewport_cells` returns nil (falls through) for a non-viewport string.
      if expr.includes?('v') || expr.includes?('V')
        scr = window
        if cells = CSS::Length.viewport_cells(expr, scr.awidth, scr.aheight)
          return cells
        end
      end
      if expr == aliased
        expr = "50%"
      elsif expr.starts_with?(aliased) && (c = expr[aliased.size]?) && (c == '+' || c == '-')
        # `center+5`/`half-3`: 50% of the parent plus the offset, parsed in
        # place rather than rebuilding `"50%" + expr[aliased.size..]`, which
        # would allocate two Strings per call, every frame.
        bytes = expr.to_slice
        off = 0
        j = aliased.size + 1
        while j < bytes.size
          off = off * 10 + (bytes.unsafe_fetch(j).to_i - '0'.ord)
          j += 1
        end
        off = -off if c == '-'
        return (parent_dim * 0.5).to_i + off
      end
      Widget.dimension(expr, parent_dim)
    end

    # Whether a position value asks to be centered — `"center"` or an offset form
    # like `"center+5"` / `"center-3"`. Centered widgets pull back by half their
    # size and skip the near-side inner offset.
    private def center_expr?(o) : Bool
      o.is_a?(String) && (o == "center" || o.starts_with?("center+") || o.starts_with?("center-"))
    end

    # Whether the parent's near-side inner offset (`ileft`/`itop`) applies to a
    # widget whose primary edge is `o` and opposite edge is `o_opp`. The actual
    # `+=`/`-=` stays at each call site since it differs by axis/direction.
    private def applies_near_offset?(o, o_opp) : Bool
      (!o.nil? || o_opp.nil?) && !center_expr?(o)
    end

    # Returns computed absolute left position.
    #
    # `width`, when given, is this widget's already-resolved `awidth(get)`, needed
    # by the right-anchored and `"center"` branches; passing it in avoids a second
    # `awidth` walk per frame. When nil it is resolved on demand.
    def aleft(get = false, width = nil, parent_pos = nil, with_margin = true)
      # Original left
      oleft = @left
      oright = @right

      mg = style.margin

      # Right-anchored: the outward margin pushes the box LEFT by its own right
      # margin. Included so hit-test geometry (`Window#widget_at` /
      # `#contains_point?`) matches where `_get_coords` paints it; `_get_coords`
      # and the anchoring callers below pass `with_margin: false` so the shift is
      # applied exactly once.
      if oleft.nil? && !oright.nil?
        mr = (with_margin && mg.any?) ? mg.right : 0
        return window.awidth - (width || awidth(get)) - aright(get) - mr
      end

      # Left-anchored: the outward margin pushes the box RIGHT by its own left
      # margin (see above for why it's gated on `with_margin`).
      ml = (with_margin && mg.any?) ? mg.left : 0

      # `parent_pos`, when given, is the parent's already-resolved position for
      # this frame, threaded in by `_get_coords` so `aleft`/`atop` don't re-resolve.
      parent = parent_pos || (get ? parent_or_window.last_rendered_position : parent_or_window)

      left = oleft || 0
      if left.is_a? String
        left = resolve_dimension(left, parent.awidth || 0, "center")
        if center_expr?(oleft)
          left -= (width || awidth(get)) // 2
        end
      end

      if applies_near_offset?(oleft, oright)
        left += parent.ileft
      end

      (parent.aleft || 0) + left + ml
    end

    # Returns computed absolute top position. `height`, when given, is this
    # widget's already-resolved `aheight(get)` — see `#aleft` (avoids a redundant
    # `aheight` walk for bottom-anchored / `"center"` widgets).
    def atop(get = false, height = nil, parent_pos = nil, with_margin = true)
      otop = @top
      obottom = @bottom

      mg = style.margin

      # See `#aleft`: bottom-anchored, the outward margin pushes the box UP by
      # its own bottom margin.
      if otop.nil? && !obottom.nil?
        mb = (with_margin && mg.any?) ? mg.bottom : 0
        return window.aheight - (height || aheight(get)) - abottom(get) - mb
      end

      # See `#aleft`: top-anchored, the outward margin pushes the box DOWN by its
      # own top margin.
      mt = (with_margin && mg.any?) ? mg.top : 0

      # See `#aleft`: `parent_pos` is the parent's already-resolved position.
      parent = parent_pos || (get ? parent_or_window.last_rendered_position : parent_or_window)

      top = otop || 0
      if top.is_a? String
        top = resolve_dimension(top, parent.aheight || 0, "center")
        if center_expr?(otop)
          top -= (height || aheight(get)) // 2
        end
      end

      if applies_near_offset?(otop, obottom)
        top += parent.itop
      end

      (parent.atop || 0) + top + mt
    end

    # Returns computed absolute right position
    def aright(get = false)
      oleft = @left
      oright = @right

      parent = get ? parent_or_window.last_rendered_position : parent_or_window

      if oright.nil? && !oleft.nil?
        # Base geometry: `_get_coords` composes in the margin, so this far-edge
        # offset must not double-count it.
        right = window.awidth - (aleft(get, with_margin: false) + awidth(get))
        right += parent.iright
        return right
      end

      right = (parent.aright || 0) + (oright || 0)
      right += parent.iright

      right
    end

    # Returns computed absolute bottom position
    def abottom(get = false)
      otop = @top
      obottom = @bottom

      parent = get ? parent_or_window.last_rendered_position : parent_or_window

      if obottom.nil? && !otop.nil?
        # Base geometry (see `#aright`): margin is composed in by `_get_coords`.
        bottom = window.aheight - atop(get, with_margin: false) - aheight(get)
        bottom += parent.ibottom
        return bottom
      end

      bottom = (parent.abottom || 0) + (obottom || 0)

      bottom += parent.ibottom

      bottom
    end

    # Shifts the `lo..hi` pair by the widget's own margin (see `_get_coords`):
    # outward by `far` when only the far side is anchored (`near_anchor` nil,
    # `far_anchor` not), otherwise outward by `near`. `near_anchor`/`far_anchor`
    # are the raw `@left`/`@right` (or `@top`/`@bottom`) values, passed through
    # untouched — this is an unconditional shift, not a bounds clamp, so it is
    # a distinct shape from `translate_into_bounds` below. Used once per axis.
    private def shift_margin(lo : Int32, hi : Int32, near_anchor, far_anchor, near : Int32, far : Int32) : {Int32, Int32}
      if near_anchor.nil? && !far_anchor.nil?
        {lo - far, hi - far}
      else
        {lo + near, hi + near}
      end
    end

    # Clamps `lo` up to at least `min` and `hi` down to at most `max`,
    # independently (a widget's edges never cross past its `ShrinkWidget`
    # parent's inner rectangle). Used once per axis.
    private def clamp_edge_pair(lo : Int32, hi : Int32, min : Int32, max : Int32) : {Int32, Int32}
      lo = min if lo < min
      hi = max if hi > max
      {lo, hi}
    end

    # Translates the `lo..hi` pair (preserving its width) so it fits within
    # `min..max`: pulls in from the far edge first, then the near edge — so a
    # span wider than `max - min` ends up anchored at `min` with overflow on
    # the far side. Used by `overflow: MoveWidget`, once per axis.
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

    # `width_hint`, when given, is this widget's already-resolved `awidth(get)`,
    # computed by `#_render` just before calling here, to skip re-resolving the
    # identical `awidth`. Only the render path passes it.
    def _get_coords(get = false, noscroll = false, into : LPos? = nil, width_hint : Int32? = nil)
      unless style.visible?
        return
      end

      # D O:
      # if @parent._rendering
      #   get = true
      # end

      # Resolve the parent (or window) and its rendered position once for the
      # whole coordinate pass, threaded through instead of `aleft`/`atop` and
      # the clip/shrink section each re-resolving it.
      por = parent_or_window
      ppos = get ? por.last_rendered_position : por

      # Resolve each dimension once, reused for both the anchored origin
      # (`aleft`/`atop`) and the far edge (`xl`/`yl`), so a right-anchored or
      # `"center"` widget doesn't walk `awidth`/`aheight` twice per frame.
      # `awidth`/`aheight` give the border-box size (an auto width already folds
      # in the margin; a fixed one does not — see `Widget#awidth`); the margin
      # block below only *shifts* this box. The origin getters are called with
      # `with_margin: false` so the shift is applied here exactly once.
      # `width_hint` is `awidth(get)`, computed by `#_render` just before.
      w = width_hint || awidth(get)
      h = aheight(get)
      xi = aleft(get, w, ppos, with_margin: false)
      xl = xi + w
      yi = atop(get, h, ppos, with_margin: false)
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
      if resizable?
        coords = _minimal_rectangle(xi, xl, yi, yl, get)
        xi = coords.xi
        xl = coords.xl
        yi = coords.yi
        yl = coords.yl
      end

      # Apply the element's own margin, CSS-style (*outward*): the border box
      # keeps its size and is pushed away from its anchored edge by the near
      # margin — right/left when right/left-anchored, so the margin reserves
      # space *outside* the box rather than eating into it. (A stretched auto
      # size already had its margin folded into `awidth`/`aheight`, so shifting
      # is all that remains; a fixed size never shrinks.)
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

      # Old way of doing things, this would not render right if a shrunken element
      # with lots of boxes in it was within a scrollable element.
      # See: $ c test/widget-shrink-fail.cr
      # scrollable_parent = @parent

      # First/closest clipping parent (scrollable, or `overflow: Hidden`). Named
      # `scrollable_parent` for historical reasons; for a Hidden parent the
      # scroll-specific terms (`.base`) are simply zero.
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

        # D O:
        # The resizable option can cause a stack overflow
        # by calling _get_coords on the child again.
        # if !get && !scrollable_parent.resizable?
        #   scrollable_parent_lpos = scrollable_parent._get_coords()
        # end

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
        # the bottom clip against the parent's BOTTOM border and the horizontal
        # clips against the LEFT/RIGHT borders. Reusing `b` (the top border) for
        # all edges mis-clips asymmetric borders (e.g. `border-top-width: 1;
        # border-bottom-width: 0`, or a left border of 1 with `left: -1`).
        bb = sp_border.bottom
        bl = sp_border.left
        br = sp_border.right

        # D O:
        # XXX
        # Fixes non-`fixed` labels to work with scrolling (they're ON the border):
        # if @left < 0 || @right < 0 || @top < 0 || @bottom < 0
        # This exempts a widget that *is* a label (sits ON the parent's border)
        # from border compensation — blessed's `if (this._isLabel) b = 0`.
        # Testing `@_label` instead ("widget HAS a label") is the wrong
        # direction: it would clip labels out of scrollable widgets and zero all
        # four compensations for any labeled child in a scrolled container.
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

        # D O:
        # Shouldn't be necessary.
        # (yi < yl) || raise "No good"
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
        # D O:
        # if xi > xl
        #  return
        # end
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
      # area, preserving size (e.g. a completion list that would run off the
      # bottom slides up to stay on window). Unlike `ShrinkWidget` (parent-policy,
      # clamps edges), this is child-policy: the widget declares it for itself.
      # Far edges are pulled in first, then near edges clamped, so a widget
      # larger than the window starts at top/left with overflow on the far side.
      if self.overflow.move_widget?
        scr = window
        s_left = scr.ileft
        s_top = scr.itop
        s_right = scr.awidth - scr.iright
        s_bottom = scr.aheight - scr.ibottom

        xi, xl = translate_into_bounds(xi, xl, s_left, s_right)
        yi, yl = translate_into_bounds(yi, yl, s_top, s_bottom)
      end

      # D O:
      # if parent.lpos
      #   parent.lpos._scroll_bottom = Math.max(parent.lpos._scroll_bottom, yl)
      # end
      # p xi, xl, yi, xl

      # Reuse the widget's existing `LPos` when the caller offers one (the render
      # hot path passes `@lpos`), turning a per-frame heap allocation into an
      # in-place update. All early returns above precede this, so `into` is
      # never mutated on a path that yields no coords.
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
        v = LPos.new \
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
