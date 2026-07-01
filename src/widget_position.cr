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
      # `to_f?` (not `to_f`) so a non-clean percentage (e.g. `0.5em` -> `0.5e`)
      # yields 0 rather than raising — last-line guard so layout never aborts.
      pct = (expr.byte_slice(0, pct_end).to_f? || 0.0) / 100

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
      emit ::Crysterm::Event::Move
      @left = val
      mark_dirty
    end

    # Sets Widget's `@top`
    def top=(val)
      return if @top == val
      emit ::Crysterm::Event::Move
      @top = val
      mark_dirty
    end

    # Sets Widget's `@right`
    def right=(val)
      return if @right == val
      emit ::Crysterm::Event::Move
      @right = val
      mark_dirty
    end

    # Sets Widget's `@bottom`
    def bottom=(val)
      return if @bottom == val
      emit ::Crysterm::Event::Move
      @bottom = val
      mark_dirty
    end

    #
    # Computed relative position on window
    #

    # Returns computed relative left position
    def rleft
      (aleft || 0) - (parent_or_window.aleft || 0)
    end

    # Returns computed relative top position
    def rtop
      (atop || 0) - (parent_or_window.atop || 0)
    end

    # Returns computed relative right position
    def rright
      (aright || 0) - (parent_or_window.aright || 0)
    end

    # Returns computed relative bottom position
    def rbottom
      (abottom || 0) - (parent_or_window.abottom || 0)
    end

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
        # `center+5`/`half-3`: map the alias prefix to `50%`, keeping the offset.
        expr = "50%" + expr[aliased.size..]
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
      # Include the widget's own left margin so hit-test geometry
      # (`Window#widget_at` / `#contains_point?`) matches where `_get_coords`
      # paints it (`xi += margin.left`); otherwise a margined widget was
      # clickable a column off. `_get_coords` and the anchoring callers below
      # pass `with_margin: false` so the margin is applied exactly once.
      ml = (with_margin && (mg = style.margin).any?) ? mg.left : 0

      # Original left
      oleft = @left
      oright = @right

      if oleft.nil? && !oright.nil?
        return ml + window.awidth - (width || awidth(get, with_margin: false)) - aright(get)
      end

      # `parent_pos`, when given, is the parent's already-resolved position for
      # this frame, threaded in by `_get_coords` so `aleft`/`atop` don't re-resolve.
      parent = parent_pos || (get ? parent_or_window.last_rendered_position : parent_or_window)

      left = oleft || 0
      if left.is_a? String
        left = resolve_dimension(left, parent.awidth || 0, "center")
        if center_expr?(oleft)
          left -= (width || awidth(get, with_margin: false)) // 2
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
      # See `#aleft`: include own top margin (`_get_coords` does `yi +=
      # margin.top`) to keep hit-testing aligned with the paint.
      mt = (with_margin && (mg = style.margin).any?) ? mg.top : 0

      otop = @top
      obottom = @bottom

      if otop.nil? && !obottom.nil?
        return mt + window.aheight - (height || aheight(get, with_margin: false)) - abottom(get)
      end

      # See `#aleft`: `parent_pos` is the parent's already-resolved position.
      parent = parent_pos || (get ? parent_or_window.last_rendered_position : parent_or_window)

      top = otop || 0
      if top.is_a? String
        top = resolve_dimension(top, parent.aheight || 0, "center")
        if center_expr?(otop)
          top -= (height || aheight(get, with_margin: false)) // 2
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
        right = window.awidth - (aleft(get, with_margin: false) + awidth(get, with_margin: false))
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
        bottom = window.aheight - atop(get, with_margin: false) - aheight(get, with_margin: false)
        bottom += parent.ibottom
        return bottom
      end

      bottom = (parent.abottom || 0) + (obottom || 0)

      bottom += parent.ibottom

      bottom
    end

    # (Removed: ~65 lines of disabled `aleft=`/`aright=`/`atop=`/`abottom=`
    # setters — "Disabled because nothing uses these, and not resize-safe."
    # Recoverable from git history if ever needed.)

    # `width_hint`, when given, is this widget's already-resolved `awidth(get)`,
    # computed by `#_render` just before calling here, to skip re-resolving the
    # identical `awidth`. Only the render path passes it.
    # ameba:disable Metrics/CyclomaticComplexity
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
      # `"center"` widget doesn't walk `awidth`/`aheight` twice per frame. Built
      # without the element's own margin (the margin block below composes it in
      # exactly once) — getters are called with `with_margin: false` to keep
      # this rectangle byte-identical. `width_hint` is `awidth(true)`, already
      # margin-shrunk, so the horizontal margin is added back when given.
      w = if wh = width_hint
            wh + ((mg = style.margin).any? ? mg.left + mg.right : 0)
          else
            awidth(get, with_margin: false)
          end
      h = aheight(get, with_margin: false)
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

      # Apply the element's own margin: an outer inset shifting the box in by
      # near-side margins and shrinking it by far-side ones — mirrors the
      # border/padding insets (`ileft` & co.) but at the outer edge.
      # `_minimal_rectangle` reserves room for it (see `Widget#mwidth`/`mheight`),
      # so a shrunk widget keeps its content intact.
      if (margin = style.margin).any?
        xi += margin.left
        xl -= margin.right
        yi += margin.top
        yl -= margin.bottom
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
        # Old code: b = scrollable_parent.border ? 1 : 0

        # D O:
        # XXX
        # Fixes non-`fixed` labels to work with scrolling (they're ON the border):
        # if @left < 0 || @right < 0 || @top < 0 || @bottom < 0
        if @_label
          b = 0
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
        if yl > scrollable_parent_lpos.yl - b
          if yi > scrollable_parent_lpos.yl - 1 - b
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
        if xi < scrollable_parent_lpos.xi
          xi = scrollable_parent_lpos.xi
          no_left = true
          xi -= my_border.left
          xi += sp_border.left
        end
        if xl > scrollable_parent_lpos.xl
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
        if xi < plp.xi + parent.ileft
          xi = plp.xi + parent.ileft
        end
        if xl > plp.xl - parent.iright
          xl = plp.xl - parent.iright
        end
        if yi < plp.yi + parent.itop
          yi = plp.yi + parent.itop
        end
        if yl > plp.yl - parent.ibottom
          yl = plp.yl - parent.ibottom
        end
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

        if xl > s_right
          d = xl - s_right; xi -= d; xl -= d
        end
        if xi < s_left
          d = s_left - xi; xi += d; xl += d
        end
        if yl > s_bottom
          d = yl - s_bottom; yi -= d; yl -= d
        end
        if yi < s_top
          d = s_top - yi; yi += d; yl += d
        end
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
