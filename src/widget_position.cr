module Crysterm
  class Widget
    # Methods related to 2D position (X and Y).
    # Position in 3D (index) is in widget_index.cr

    # Resolves a percentage position/size expression against the parent
    # dimension `dim`. Accepts `"50%"`, `"50%+5"`, `"50%-3"` (callers pre-map
    # `"center"`/`"half"` to `"50%"`); returns `(dim * pct).to_i + offset`.
    #
    # This replaces six identical inline blocks in `widget_position`/
    # `widget_size` that each did `expr.split(/(?=\+|-)/)` — a regex match plus
    # an `Array(String)` of parameter strings — on EVERY `aleft`/`atop`/
    # `awidth`/`aheight` call (i.e. several times per widget per frame). Here the
    # `+`/`-` offset separator is found with a byte scan, the offset is parsed
    # without allocating, and only the percentage number is materialized (to
    # keep `to_f`'s decimal support, e.g. `"33.5%"`). Pure (depends only on its
    # args), so it is unit-tested directly.
    def self.dimension(expr : String, dim : Int32) : Int32
      bytes = expr.to_slice

      # Find the offset separator (`+`/`-`). It never sits at index 0 for valid
      # input, and the byte before it is the trailing `%` of the percentage.
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
      # `to_f?` (not `to_f`) so a value that isn't a clean percentage — e.g. a
      # CSS length with a unit that slipped through (`0.5em` -> `0.5e`) — yields
      # 0 rather than raising `Invalid Float64`. Geometry already drops unit'd
      # values upstream; this is the last-line guard so layout never aborts.
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
    # Left/top/right/bottom getters and setters. These values are exactly what the user has set, rather than being computed.
    # (I.e. they are equivalent of `widget.position` in blessed.)
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
    # Computed relative position on screen
    #

    # Returns computed relative left position
    def rleft
      (aleft || 0) - (parent_or_screen.aleft || 0)
    end

    # Returns computed relative top position
    def rtop
      (atop || 0) - (parent_or_screen.atop || 0)
    end

    # Returns computed relative right position
    def rright
      (aright || 0) - (parent_or_screen.aright || 0)
    end

    # Returns computed relative bottom position
    def rbottom
      (abottom || 0) - (parent_or_screen.abottom || 0)
    end

    #
    # Computed absolute position on screen
    #

    # Resolves a `String` position/size expression to an absolute cell count
    # against `parent_dim`, first mapping the *aliased* word ("center" for
    # positions, "half" for sizes) to "50%". Shared by `aleft`/`atop`/`awidth`/
    # `aheight`; `aliased` is passed (rather than mapping both words) so an
    # unusual input like `width: "center"` keeps its original meaning.
    private def resolve_dimension(expr : String, parent_dim : Int32, aliased : String) : Int32
      # Viewport units resolve against the *screen*, not the parent — and they do
      # so here, every frame, so a `width: 50vw` widget re-sizes on terminal
      # resize. The unit picks the basis (`vw`→screen width, `vh`→height,
      # `vmin`/`vmax`→the smaller/larger side) regardless of which edge/size this
      # is, exactly like CSS.
      #
      # `resolve_dimension` is on the per-frame layout hot path (every `"50%"`/
      # `"center"`/`"half"` widget hits it). A viewport unit is the only form
      # containing a `'v'`, so this allocation-free byte scan gates the heavier
      # regex, keeping the common percentage/keyword path untouched. When a `'v'`
      # is present we resolve in one shot: `viewport_cells` returns `nil` for a
      # non-viewport string (which then falls through), and a real `0`-cell
      # result is truthy, so it still returns here.
      if expr.includes?('v')
        scr = screen
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

    # Whether a position value asks to be centered — `"center"` or, now, an
    # offset form like `"center+5"` / `"center-3"`. Centered widgets pull back by
    # half their size and skip the near-side inner offset.
    private def center_expr?(o) : Bool
      o.is_a?(String) && (o == "center" || o.starts_with?("center+") || o.starts_with?("center-"))
    end

    # Whether the parent's near-side inner offset (`ileft`/`itop`) applies to a
    # widget whose primary edge is `o` and opposite edge is `o_opp`. Identical
    # guard in `aleft`/`atop`/`awidth`/`aheight`; the actual `+=`/`-=` of the
    # offset stays at each call site since it differs by axis/direction.
    private def applies_near_offset?(o, o_opp) : Bool
      (!o.nil? || o_opp.nil?) && !center_expr?(o)
    end

    # Returns computed absolute left position.
    #
    # `width`, when given, is this widget's already-resolved `awidth(get)` — the
    # right-anchored and `"center"` branches need it, and `_get_coords` has
    # computed it once anyway, so passing it in avoids a second `awidth` walk per
    # frame for those widgets. When nil it is resolved on demand as before.
    def aleft(get = false, width = nil)
      # Original left
      oleft = @left
      oright = @right

      if oleft.nil? && !oright.nil?
        return screen.awidth - (width || awidth(get)) - aright(get)
      end

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

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

      (parent.aleft || 0) + left
    end

    # Returns computed absolute top position. `height`, when given, is this
    # widget's already-resolved `aheight(get)` — see `#aleft` for why this is
    # passed in (avoids a redundant `aheight` walk for bottom-anchored /
    # `"center"` widgets).
    def atop(get = false, height = nil)
      otop = @top
      obottom = @bottom

      if otop.nil? && !obottom.nil?
        return screen.aheight - (height || aheight(get)) - abottom(get)
      end

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

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

      (parent.atop || 0) + top
    end

    # Returns computed absolute right position
    def aright(get = false)
      oleft = @left
      oright = @right

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      if oright.nil? && !oleft.nil?
        right = screen.awidth - (aleft(get) + awidth(get))
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

      parent = get ? parent_or_screen.last_rendered_position : parent_or_screen

      if obottom.nil? && !otop.nil?
        bottom = screen.aheight - atop(get) - aheight(get)
        bottom += parent.ibottom
        return bottom
      end

      bottom = (parent.abottom || 0) + (obottom || 0)

      bottom += parent.ibottom

      bottom
    end

    # XXX Disabled because nothing uses these at the moment, and also they
    # are not resize-safe. Widget will remain in the old/unresized position
    # after a resize.
    #
    # def aleft=(val)
    #  if val.is_a? String
    #    if (val == "center")
    #      val = screen.awidth // 2
    #      val -= @width // 2
    #    else
    #      expr = val.split(/(?=\+|-)/)
    #      val = expr[0]
    #      val = val.slice[0...-1].to_f / 100
    #      val = (screen.awidth * val).to_i
    #      val += expr[1] if expr[1]?
    #    end
    #  end
    #  val -= parent_or_screen.aleft
    #  if @left == val
    #    return
    #  end
    #  clear_last_rendered_position
    #  @left = val
    #  emit ::Crysterm::Event::Move
    #  val
    # end

    # def aright=(val)
    #  val -= parent_or_screen.aright
    #  return if @right == val
    #  clear_last_rendered_position
    #  @right = val
    #  emit ::Crysterm::Event::Move
    #  val
    # end

    # def atop=(val)
    #  if val.is_a? String
    #    if val == "center"
    #      val = screen.aheight // 2
    #      val -= height // 2
    #    else
    #      expr = val.split(/(?=\+|-)/)
    #      val = expr[0].to_i
    #      val = val[0...-1].to_f / 100
    #      val = (screen.aheight * val).to_i
    #      val += expr[1] if expr[1]?
    #    end
    #  end
    #  val -= parent_or_screen.atop
    #  return if @top == val
    #  clear_last_rendered_position
    #  @top = val
    #  emit ::Crysterm::Event::Move
    #  val
    # end

    # def abottom=(val)
    #  val -= parent_or_screen.abottom
    #  return if @bottom == val
    #  clear_last_rendered_position
    #  @bottom = val
    #  emit ::Crysterm::Event::Move
    #  val
    # end

    # `width_hint`, when given, is this widget's already-resolved `awidth(get)`.
    # `#_render` computes it (to feed `process_content`) immediately before
    # calling here, and the first thing this method does is resolve `awidth`
    # again — the identical call, since nothing in between changes the widget's
    # width — so the hint lets us skip that second resolution. Only the render
    # path passes it; other callers (`get == false`) resolve on demand as before.
    # ameba:disable Metrics/CyclomaticComplexity
    def _get_coords(get = false, noscroll = false, into : LPos? = nil, width_hint : Int32? = nil)
      unless style.visible?
        return
      end

      # D O:
      # if @parent._rendering
      #   get = true
      # end

      # Resolve each dimension once and reuse it for both the anchored-origin
      # computation (`aleft`/`atop`) and the far edge (`xl`/`yl`). Without this,
      # a right-anchored or `"center"`-positioned widget walked `awidth` twice
      # (and likewise `aheight`) every frame.
      w = width_hint || awidth(get)
      h = aheight(get)
      xi = aleft(get, w)
      xl = xi + w
      yi = atop(get, h)
      yl = yi + h

      # Informs us which side is partly hidden due to being enclosed in a
      # parent (and potentially scrollable) element. Will be set/computed later.
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

      # Apply the element's own margin: an *outer* inset that shifts the box in by
      # the near-side margins and shrinks it by the far-side ones. This is the
      # mirror of the border/padding content insets (`ileft` & co.), but at the
      # outer edge and belonging to the element itself rather than its parent, so
      # it is applied here to the already-resolved rectangle rather than via the
      # `i*` offsets. `_minimal_rectangle` reserves room for it (see
      # `Widget#mwidth`/`mheight`), so a shrunk widget keeps its content intact.
      if (margin = style.margin).any?
        xi += margin.left
        xl -= margin.right
        yi += margin.top
        yl -= margin.bottom
      end

      # Find the nearest ancestor that clips its children, if any. Two kinds of
      # ancestor clip: a scrollable element (clips to its scroll viewport) or an
      # element with `overflow: Hidden` (clips to its rectangle even though it
      # does not scroll). Both are handled by the same block below; a Hidden,
      # non-scrollable parent simply has `child_base == 0`, so the scroll-offset
      # math degenerates to a plain clip.
      while el = el.parent
        if el.scrollable? || el.overflow.hidden?
          # `fixed` widgets (e.g. labels sitting on a border) are exempt from
          # *scroll* clipping, but not from `overflow: Hidden` clipping.
          if fixed && el.scrollable?
            fixed = false
            next
          end
          break
        end
      end

      # Check to make sure we're visible and
      # inside of the visible scroll area.
      # Note: Lists have a property where only
      # the list items are obfuscated.

      # Old way of doing things, this would not render right if a shrunken element
      # with lots of boxes in it was within a scrollable element.
      # See: $ c test/widget-shrink-fail.cr
      # scrollable_parent = @parent

      # First/closest clipping parent (scrollable, or `overflow: Hidden`).
      # Named `scrollable_parent` for historical reasons; for a Hidden parent
      # the scroll-specific terms (`.base`) are simply zero.
      scrollable_parent = el

      # Using scrollable_parent && el here to restrict both to non-nil
      if scrollable_parent && !noscroll
        # This is an intentional assignment:
        unless scrollable_parent_lpos = scrollable_parent.lpos
          # The scrollable ancestor has not been laid out yet (its `lpos` is
          # only computed during rendering). This happens when coordinates are
          # requested before the first render, e.g. editing list/box content
          # via `set_content`/`set_item`/`insert_item` up front. We simply have
          # no coordinates to report yet, so return nil (the same signal used
          # above for invisible widgets) and let callers degrade gracefully.
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

        # `style.border` is always non-nil now (a zero border means "no border";
        # see Style#border), so the `.try` blocks below always executed anyway.
        # Fetch both borders once and use them directly — no per-adjustment
        # closure, and no repeated `style`/`border` getter calls.
        my_border = style.border
        sp_border = scrollable_parent.style.border

        b = sp_border.top
        # Old code for the above was:
        # b = scrollable_parent.border ? 1 : 0
        # I hope this was referring to the top border and that the replacement/improvement
        # to support variable border width was correct.

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

        # NOTE: This is a separate `if` (not `elsif` paired with the top check
        # above): a widget can overflow BOTH the top and the bottom of its
        # scrollable parent's visible region at the same time, namely whenever
        # the widget is at least as tall as that region. With an `elsif`, once
        # the top got clipped the bottom clip was skipped, so the widget would
        # render past the parent's bottom edge (overflow leak). The horizontal
        # clipping below already uses two independent `if`s for the same reason.
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

      parent = parent_or_screen

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

      # `MoveWidget`: translate the whole rectangle so it fits within the
      # screen's visible area, preserving its size (the use case is pop-ups —
      # e.g. an auto-completion list placed below its box that would run off the
      # bottom; it slides up just enough to stay on screen). Unlike
      # `ShrinkWidget` (parent-policy, clamps the edges), this is child-policy:
      # the widget declares `overflow = MoveWidget` for itself. Far edges are
      # pulled in first, then the near edges are clamped, so a widget larger than
      # the screen still starts at the top/left with the overflow on the far side
      # ("if possible").
      if self.overflow.move_widget?
        scr = screen
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
      # hot path passes `@lpos`), turning a per-widget, per-frame heap allocation
      # into an in-place field update. All early `return`s above happen before
      # this point, so `into` is never mutated on a path that yields no coords.
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
          renders: screen.renders
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
          renders: screen.renders
      end
      v
    end
  end
end
