require "./macros"

module Crysterm
  class Widget
    include Macros

    # Widget's size

    # User-defined width (setter is defined below)
    getter width : Int32 | String | Nil

    # User-defined height (setter is defined below)
    getter height : Int32 | String | Nil

    # Whether the widget sizes itself to its content and children rather than to
    # its slot — roughly CSS `width: fit-content`. Only the dimensions the user
    # left unset (`nil` `width`/`height`) shrink.
    #
    # NOTE This has nothing to do with the *user* being able to resize the widget
    # (Qt's size policies, CSS `resize:`) — for a draggable resize handle see
    # `Widget::SizeGrip`.
    property? shrink_to_fit = false

    # `width=`/`height=`: change-guarded setters that mark dirty and emit
    # `Resize`. The assign lands *before* the emit so in-tree Resize listeners
    # observe the new size, not the old one.
    {% for dim in %w[width height] %}
      # Sets widget's total {{dim.id}}
      change_guarded_setter {{dim.id}}, Resize
    {% end %}

    # CSS `min-width`/`max-width`/`min-height`/`max-height` constraints, in cells
    # (`nil` = unconstrained). `awidth`/`aheight` clamp the *used* size to
    # `[min, max]`, with `min` winning when it exceeds `max`, like CSS. Set from a
    # stylesheet by `CSS::Geometry`; settable directly too.
    #
    # NOTE These are **cells only** — unlike `#width`/`#height` (and
    # `#left`/`#top`/`#right`/`#bottom`), a percentage `String` is not accepted;
    # `min_width: "50%"` is a compile error. Supporting it would mean resolving
    # the percentage against the parent inside `awidth`/`aheight`, where the
    # clamp runs.
    getter min_width : Int32? = nil
    getter max_width : Int32? = nil
    getter min_height : Int32? = nil
    getter max_height : Int32? = nil

    # `min_*=`/`max_*=` alter effective `awidth`/`aheight` like `width=`/`height=`,
    # so they emit `Resize` too, or its listeners go stale. Assign-before-emit, so
    # those listeners see the new constraint.
    {% for dim in %w[min_width max_width min_height max_height] %}
      change_guarded_setter {{dim.id}}, Resize, Int32?
    {% end %}

    # Clamps a computed dimension to `[min, max]`. `max` is applied before `min`
    # so `min` wins a `min > max` conflict, per CSS.
    private def clamp_dim(v : Int32, min : Int32?, max : Int32?) : Int32
      v = Math.min(v, max) if max
      v = Math.max(v, min) if min
      v
    end

    # Clamps a computed width to the `[min_width, max_width]` constraints.
    private def clamp_awidth(w : Int32) : Int32
      clamp_dim w, @min_width, @max_width
    end

    # :ditto: for height.
    private def clamp_aheight(h : Int32) : Int32
      clamp_dim h, @min_height, @max_height
    end

    # Returns computed width, in cells.
    #
    # *rendered* resolves against the parent's **last-rendered** position instead
    # of its live geometry — what the render path wants, since the parent has
    # already been placed for this frame.
    def awidth(rendered = false) : Int32
      oleft = @left
      oright = @right
      width = @width

      # Parent's rendered position is only needed by the String/`nil` branches;
      # a fixed `Int32` width (common case) ignores it, so it's resolved lazily
      # to avoid walking the ancestor chain every frame.
      case width
      when String
        parent = rendered ? parent_or_window.last_rendered_position : parent_or_window
        # Percentage of the parent's content area (inside border/padding), like
        # CSS `width: 100%`. Matching `aleft` adds the parent's near inset, so a
        # `left: 0` child sits inside the border and `"100%"` reaches the far inset.
        # A specified size keeps its full extent — an outward margin *shifts* it
        # (see `coords`), it does not shrink it.
        return clamp_awidth(resolve_dimension(width, (parent.awidth || 0) - parent.ileft - parent.iright, "half"))
      end

      # Stretched or shrunken element: shrunken widths are computed in the
      # render function from content width, seeded by the element's own width,
      # so it's calculated here too.
      if width.nil?
        parent = rendered ? parent_or_window.last_rendered_position : parent_or_window
        # `parent.awidth` climbs the whole ancestor chain. It's needed twice here
        # (string base + width subtraction); computing it once collapses
        # O(2^depth) to O(depth) for a chain of nil-width + string-left widgets.
        pw = parent.awidth || 0
        left = oleft || 0
        if left.is_a? String
          left = resolve_dimension(left, pw, "center")
        end
        # `pw` is already resolved here, so the symmetric `String` right
        # (`right: "50%"`) costs nothing extra — see `#resolve_edge`.
        width = pw - resolve_edge(oright, pw) - left

        if applies_near_offset?(oleft, oright)
          width -= parent.ileft
        end
        width -= parent.iright

        # `width: auto` fills the slot, so the element's *own* margins eat into
        # the filled content (CSS: a stretched box shrinks by its margins); a fixed
        # width keeps its size and shifts instead, so only this branch folds the
        # margin in. Subtract before clamping, so `[min_width, max_width]` applies
        # to the post-margin (used) size, per CSS min/max semantics.
        mw = (mg = style.margin).any? ? mg.left + mg.right : 0
        return clamp_awidth(width - mw)
      end

      # Every `String` returned above and every `nil` in the branch above it, so
      # only an `Int32` reaches here; the `as` states that for the return type.
      clamp_awidth(width.as(Int32))
    end

    # Returns computed height, in cells. See `#awidth` for *rendered*.
    def aheight(rendered = false) : Int32
      otop = @top
      obottom = @bottom
      height = @height

      # See `awidth`: parent's rendered position is only needed by the
      # String/`nil` branches, resolved lazily rather than on every call.
      case height
      when String
        parent = rendered ? parent_or_window.last_rendered_position : parent_or_window
        # Percentage of the parent's content height; see `awidth` for rationale.
        # A specified size keeps its full extent (outward margin shifts it).
        return clamp_aheight(resolve_dimension(height, (parent.aheight || 0) - parent.itop - parent.ibottom, "half"))
      end

      # Stretched or shrunken element: shrunken height is computed in the render
      # function but seeded by the content height, which is initially decided
      # by the element's own height, so it's calculated here too.
      if height.nil?
        parent = rendered ? parent_or_window.last_rendered_position : parent_or_window
        # See `awidth`: one `parent.aheight` shared between string base and height
        # subtraction. O(2^depth) → O(depth).
        ph = parent.aheight || 0
        top = otop || 0
        if top.is_a? String
          top = resolve_dimension(top, ph, "center")
        end
        # See `#awidth`: `ph` is already resolved, so a `String` bottom is free.
        height = ph - resolve_edge(obottom, ph) - top

        if applies_near_offset?(otop, obottom)
          height -= parent.itop
        end
        height -= parent.ibottom

        # See `awidth`: only an auto (stretched) height folds in the element's own
        # margins, and the margin comes off before the clamp.
        mh = (mg = style.margin).any? ? mg.top + mg.bottom : 0
        return clamp_aheight(height - mh)
      end

      # See `#awidth`: only an `Int32` can reach here.
      clamp_aheight(height.as(Int32))
    end

    # Returns minimum widget size based on bounding box
    private def minimal_children_rectangle(xi, xl, yi, yl, rendered)
      if @children.empty?
        return Rectangle.of_edges left: xi, top: yi, right: xi + 1, bottom: yi + 1
      end

      mxi = xi
      mxl = xi + 1
      myi = yi
      myl = yi + 1

      # Chicken-and-egg: determining this element's render needs the children's
      # render, but the children need to know their parent's render — so give
      # them what we have so far.
      if rendered
        _lpos = @lpos
        # A reused per-widget scratch — children only read it transiently via
        # `parent.lpos` during this pass — NOT `@lpos` itself: provisional and
        # final coords differ.
        @lpos = (@_shrink_lpos ||= RenderedGeometry.new).reset(
          xi: xi, xl: xl, yi: yi, yl: yl, base: 0,
          no_left: false, no_right: false, no_top: false, no_bottom: false,
          renders: 0)
      end

      # One reused scratch for every child's coordinate result: it's read (and for
      # anchored children adjusted) within the iteration only, so a heap
      # `RenderedGeometry` per child per frame would be pure garbage. Distinct
      # from `@_shrink_lpos` above, which is exposed via `@lpos` for the same pass.
      scratch = (@_shrink_child_lpos ||= RenderedGeometry.new)
      @children.each do |el|
        # Skip layout-excluded chrome, exactly as the layout engines do: the
        # background-image `Media` layer is pinned 0/0/0/0 (spanning the whole
        # current slot), so measuring it would lock a shrink-to-content widget at
        # whatever size the previous frame stretched the layer to — the widget
        # balloons to its parent's full size and never shrinks again.
        next if el.layout_excluded?
        ret = el.coords(rendered, into: scratch)

        if !ret
          next
        end

        # A shrunk parent's children assume max available space, so a
        # right/bottom-anchored child would inflate the parent's shrunken size;
        # use just the element's own height/width instead.
        if el.left.nil? && !el.right.nil?
          ret.xl = xi + (ret.xl - ret.xi)
          ret.xi = xi
          ret.xl += ileft
          ret.xi += ileft
        end
        if el.top.nil? && !el.bottom.nil?
          ret.yl = yi + (ret.yl - ret.yi)
          ret.yi = yi
          ret.yl += itop
          ret.yi += itop
        end

        mxi = Math.min(mxi, ret.xi)
        mxl = Math.max(mxl, ret.xl)
        myi = Math.min(myi, ret.yi)
        myl = Math.max(myl, ret.yl)
      end

      if rendered
        @lpos = _lpos
      end

      if @width.nil? && (@left.nil? || @right.nil?)
        if @left.nil? && !@right.nil?
          xi = xl - (mxl - mxi)
          # `mxl - mxi` already bakes in the *near* (left) inset: children sit at
          # `parent.ileft` while `mxi` is seeded to the parent's own left edge, so
          # the span is `ileft + content`. Pull the left edge back by the *far*
          # (right) inset to size the box to `content + ihorizontal` — matching
          # the left-anchored branch's `xl += iright`. Using `ileft` here would
          # double-count the near inset and over-size an asymmetrically-inset box.
          xi -= iright
        else
          xl = mxl
          xl += iright
        end
      end
      if @height.nil? && (@top.nil? || @bottom.nil?) && (!@scrollable || @_is_list)
        # Shrunken lists assume all items should be showing; height can be
        # calculated from item count.
        if @_is_list
          # Anchor the extent at the widget's own top: `myi`/`myl` are absolute
          # window coordinates, and the top-anchored placement below uses `myl`
          # absolutely. A 0-based `myi` is correct only at `yi == 0`; anywhere else
          # the rectangle comes out inverted/truncated and the span comparison in
          # `minimal_rectangle_uncached` collapses the box to its content rect.
          myi = yi
          # `@items.size` counts only content rows, and the top-anchored placement
          # below (`yl = myl; yl += ibottom`) adds only the bottom inset — so fold
          # the *top* inset in here, or a bordered shrink-to-content list comes out
          # `itop` rows short and clips its last item. `itop` (not `ibottom`), or
          # the error inverts; `myi = yi` keeps the bottom-anchored branch's span
          # (`myl - myi == items + itop`) unchanged.
          myl = yi + @items.size + itop
        end
        if @top.nil? && !@bottom.nil?
          yi = yl - (myl - myi)
          # `myl - myi` already bakes in the *near* (top) inset (see the x-axis
          # branch above), so pull the top edge back by the *far* (bottom) inset to
          # size the box to `content + ivertical`, matching the top-anchored
          # branch's `yl += ibottom`.
          yi -= ibottom
        else
          yl = myl
          yl += ibottom
        end
      end

      Rectangle.of_edges left: xi, top: yi, right: xl, bottom: yl
    end

    # Returns minimum widget size based on content.
    #
    # NOTE: the widget must not have `#align=` set, or the alignment padding
    # will make the "minimal" size come out as the surrounding box's full size.
    private def minimal_content_rectangle(xi, xl, yi, yl)
      h = @_clines.size
      # `max_width` is `property max_width = 0` (Int32, never nil), so no `|| 0`.
      w = @_clines.max_width

      # The border box is sized to exactly the content (`w`/`h` + inner insets);
      # an outward margin shifts this box rather than shrinking it (see
      # `coords`), so no margin room is reserved here.
      if @width.nil? && (@left.nil? || @right.nil?)
        if @left.nil? && !@right.nil?
          xi = xl - w - ihorizontal
        else
          xl = xi + w + ihorizontal
        end
      end

      if @height.nil? && (@top.nil? || @bottom.nil?) &&
         (!@scrollable || @_is_list)
        if @top.nil? && !@bottom.nil?
          yi = yl - h - ivertical
        else
          yl = yi + h + ivertical
        end
      end

      Rectangle.of_edges left: xi, top: yi, right: xl, bottom: yl
    end

    # Frame memo for `minimal_rectangle`: without it, nested shrink_to_fit widgets
    # re-derive the same subtree rectangle once per ancestor shrink pass plus
    # their own render — O(depth × subtree) per frame. Keyed on the exact
    # arguments plus `Window#renders`, so a moved/resized caller or a new frame
    # recomputes; `#mark_dirty` clears it eagerly.
    @_minrect : Rectangle?
    @_minrect_key : Tuple(Int32, Int32, Int32, Int32, Bool, Int32)?

    # Drops the frame-memoized `minimal_rectangle` result.
    protected def invalidate_minimal_rectangle : Nil
      @_minrect = nil
    end

    # Returns minimum widget size
    private def minimal_rectangle(xi, xl, yi, yl, rendered)
      key = {xi, xl, yi, yl, rendered, window?.try(&.renders) || -1}
      if (r = @_minrect) && @_minrect_key == key
        return r
      end
      r = minimal_rectangle_uncached(xi, xl, yi, yl, rendered)
      @_minrect = r
      @_minrect_key = key
      r
    end

    # :ditto: — the uncached computation.
    private def minimal_rectangle_uncached(xi, xl, yi, yl, rendered)
      children_rect = minimal_children_rectangle(xi, xl, yi, yl, rendered)
      content_rect = minimal_content_rectangle(xi, xl, yi, yl)
      xll = xl
      yll = yl

      # Figure out which one is bigger and use it.
      if children_rect.width > content_rect.width
        xi = children_rect.xi
        xl = children_rect.xl
      else
        xi = content_rect.xi
        xl = content_rect.xl
      end

      if children_rect.height > content_rect.height
        yi = children_rect.yi
        yl = children_rect.yl
      else
        yi = content_rect.yi
        yl = content_rect.yl
      end

      # Recenter shrunken elements (`center`/`center±N`): a shrunk widget pulled
      # its origin back by half its full width in `aleft`, so recentering by half
      # the freed space keeps an offset-centered widget from landing far off.
      if xl < xll && center_expr?(@left)
        xll = (xll - xl) // 2
        xi += xll
        xl += xll
      end

      if yl < yll && center_expr?(@top)
        yll = (yll - yl) // 2
        yi += yll
        yl += yll
      end

      Rectangle.of_edges left: xi, top: yi, right: xl, bottom: yl
    end
  end
end
