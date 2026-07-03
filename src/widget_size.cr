module Crysterm
  class Widget
    # Widget's size

    # User-defined width (setter is defined below)
    getter width : Int32 | String | Nil

    # User-defined height (setter is defined below)
    getter height : Int32 | String | Nil

    # Can Crysterm resize the widget if/when needed?
    property? resizable = false

    # Sets widget's total width
    def width=(val)
      return if @width == val
      # Assign (and mark dirty) *before* emitting so in-tree Resize listeners
      # (e.g. `Mixin::ItemView#on_resize`, `Mixin::TextEditing`'s cursor
      # recompute) observe the new size, not the old one.
      # Assign (and mark dirty) *before* emitting so in-tree Resize listeners
      # (e.g. `Mixin::ItemView#on_resize`, `Mixin::TextEditing`'s cursor
      # recompute) observe the new size, not the old one.
      @width = val
      mark_dirty
      emit ::Crysterm::Event::Resize
    end

    # Sets widget's total height
    def height=(val)
      return if height == val
      # See `width=`: assign before emit so listeners see the new size.
      @height = val
      mark_dirty
      emit ::Crysterm::Event::Resize
    end

    # CSS `min-width`/`max-width`/`min-height`/`max-height` constraints, in cells
    # (`nil` = unconstrained). `awidth`/`aheight` clamp the *used* size to
    # `[min, max]`, with `min` winning when it exceeds `max`, like CSS. Set from a
    # stylesheet by `CSS::Geometry`; settable directly too.
    getter min_width : Int32? = nil
    getter max_width : Int32? = nil
    getter min_height : Int32? = nil
    getter max_height : Int32? = nil

    {% for dim in %w[min_width max_width min_height max_height] %}
      def {{dim.id}}=(val : Int32?)
        return if @{{dim.id}} == val
        # Alters effective `awidth`/`aheight` like `width=`/`height=`, so must
        # emit `Resize` too — otherwise listeners (`Mixin::ItemView#on_resize`,
        # `Mixin::TextEditing`'s Resize→`_update_cursor`) go stale.
        # Assign before emitting so those listeners see the new constraint.
        @{{dim.id}} = val
        mark_dirty
        emit ::Crysterm::Event::Resize
      end
    {% end %}

    # Clamps a computed dimension to `[min, max]`. `max` is applied before `min`
    # so `min` wins a `min > max` conflict, per CSS. Shared by
    # `#clamp_awidth`/`#clamp_aheight`.
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

    # Returns computed width
    def awidth(get = false)
      oleft = @left
      oright = @right
      width = @width

      # Parent's rendered position is only needed by the String/`nil` branches;
      # a fixed `Int32` width (common case) ignores it, so it's resolved lazily
      # to avoid walking the ancestor chain every frame.
      case width
      when String
        parent = get ? parent_or_window.last_rendered_position : parent_or_window
        # Percentage of the parent's content area (inside border/padding), like
        # CSS `width: 100%`. Matching `aleft` adds the parent's near inset, so a
        # `left: 0` child sits inside the border and `"100%"` reaches the far inset.
        # A specified size keeps its full extent — an outward margin *shifts* it
        # (see `_get_coords`), it does not shrink it.
        return clamp_awidth(resolve_dimension(width, (parent.awidth || 0) - parent.ileft - parent.iright, "half"))
      end

      # Stretched or shrunken element: shrunken widths are computed in the
      # render function from content width, seeded by the element's own width,
      # so it's calculated here too.
      if width.nil?
        parent = get ? parent_or_window.last_rendered_position : parent_or_window
        # `parent.awidth` climbs the whole ancestor chain (or reads the stored
        # `LPos` under `get`). Needed twice here (string base + width
        # subtraction); computing it once collapses O(2^depth) to O(depth) for a
        # chain of nil-width + string-left widgets. Kept inside this branch so an
        # integer-width widget never walks the chain.
        pw = parent.awidth || 0
        left = oleft || 0
        if left.is_a? String
          left = resolve_dimension(left, pw, "center")
        end
        width = pw - (oright || 0) - left

        if applies_near_offset?(oleft, oright)
          width -= parent.ileft
        end
        width -= parent.iright

        # `width: auto` fills the slot, so the element's *own* margins eat into
        # the filled content (CSS: a stretched box shrinks by its margins). A
        # fixed width instead keeps its size and shifts (see `_get_coords`), so
        # only this auto branch folds the margin in.
        # Subtract the margin from the filled size *before* clamping so the
        # [min_width, max_width] constraints apply to the post-margin (used)
        # size, matching CSS min/max semantics.
        mw = (mg = style.margin).any? ? mg.left + mg.right : 0
        return clamp_awidth(width - mw)
      end

      width.is_a?(Int32) ? clamp_awidth(width) : width
    end

    # Returns computed height
    def aheight(get = false)
      otop = @top
      obottom = @bottom
      height = @height

      # See `awidth`: parent's rendered position is only needed by the
      # String/`nil` branches, resolved lazily rather than on every call.
      case height
      when String
        parent = get ? parent_or_window.last_rendered_position : parent_or_window
        # Percentage of the parent's content height; see `awidth` for rationale.
        # A specified size keeps its full extent (outward margin shifts it).
        return clamp_aheight(resolve_dimension(height, (parent.aheight || 0) - parent.itop - parent.ibottom, "half"))
      end

      # Stretched or shrunken element: shrunken height is computed in the render
      # function but seeded by the content height, which is initially decided
      # by the element's own height, so it's calculated here too.
      if height.nil?
        parent = get ? parent_or_window.last_rendered_position : parent_or_window
        # See `awidth`: one `parent.aheight` shared between string base and
        # height subtraction, kept inside this branch so a fixed-height widget
        # never recurses. O(2^depth) → O(depth).
        ph = parent.aheight || 0
        top = otop || 0
        if top.is_a? String
          top = resolve_dimension(top, ph, "center")
        end
        height = ph - (obottom || 0) - top

        if applies_near_offset?(otop, obottom)
          height -= parent.itop
        end
        height -= parent.ibottom

        # See `awidth`: only an auto (stretched) height folds in the element's
        # own margins; a fixed height shifts instead.
        # Subtract the margin before clamping so [min_height, max_height] apply
        # to the post-margin (used) size, matching CSS min/max semantics.
        mh = (mg = style.margin).any? ? mg.top + mg.bottom : 0
        return clamp_aheight(height - mh)
      end

      height.is_a?(Int32) ? clamp_aheight(height) : height
    end

    # Returns minimum widget size based on bounding box
    def _minimal_children_rectangle(xi, xl, yi, yl, get)
      if @children.empty?
        return Rectangle.new xi: xi, xl: xi + 1, yi: yi, yl: yi + 1
      end

      mxi = xi
      mxl = xi + 1
      myi = yi
      myl = yi + 1

      # Chicken-and-egg: determining this element's render needs the children's
      # render, but the children need to know their parent's render — so give
      # them what we have so far.
      if get
        _lpos = @lpos
        # A reused per-widget scratch (children only read it transiently via
        # `parent.lpos` during this pass), NOT `@lpos` itself — provisional and
        # final coords differ.
        @lpos = (@_shrink_lpos ||= LPos.new).reset(
          xi: xi, xl: xl, yi: yi, yl: yl, base: 0,
          no_left: false, no_right: false, no_top: false, no_bottom: false,
          renders: 0)
        # D O:
        # @resizable = false
      end

      # One reused scratch for every child's coordinate result: it's read (and
      # for anchored children adjusted) within the iteration only, so a heap
      # `LPos` per child per frame was pure garbage. Distinct from
      # `@_shrink_lpos` above, which is exposed via `@lpos` for the same pass.
      scratch = (@_shrink_child_lpos ||= LPos.new)
      @children.each do |el|
        ret = el._get_coords(get, into: scratch)

        # D O:
        # Or just (seemed to work, but probably not good):
        # ret = el.lpos || @lpos

        if !ret
          next
        end

        # A shrunk parent's children assume max available space, so a
        # right/bottom-anchored child would inflate the parent's shrunken size;
        # use just the element's own height/width instead.
        # D O:
        # if get
        if el.left.nil? && !el.right.nil?
          ret.xl = xi + (ret.xl - ret.xi)
          ret.xi = xi
          # Maybe just do this no matter what.
          ret.xl += ileft
          ret.xi += ileft
        end
        if el.top.nil? && !el.bottom.nil?
          ret.yl = yi + (ret.yl - ret.yi)
          ret.yi = yi
          # Maybe just do this no matter what.
          ret.yl += itop
          ret.yi += itop
        end

        mxi = Math.min(mxi, ret.xi)
        mxl = Math.max(mxl, ret.xl)
        myi = Math.min(myi, ret.yi)
        myl = Math.max(myl, ret.yl)
      end

      if get
        @lpos = _lpos
        # D O:
        # @resizable = true
      end

      if @width.nil? && (@left.nil? || @right.nil?)
        if @left.nil? && !@right.nil?
          xi = xl - (mxl - mxi)
          # Pull the left edge back by the full left inset (border + padding),
          # mirroring the y-axis top branch (`yi -= itop`). The prior code
          # subtracted both paddings and no border, sizing a bordered
          # right-anchored shrink box too wide by `border.left + border.right`.
          xi -= ileft
        else
          xl = mxl
          # D O:
          # xl += style.padding.try(&.right) || 0
          xl += iright
        end
      end
      if @height.nil? && (@top.nil? || @bottom.nil?) && (!@scrollable || @_is_list)
        # Shrunken lists assume all items should be showing; height can be
        # calculated from item count.
        if @_is_list
          myi = 0 - itop
          # Just the item count: the shared placement branch below adds the
          # single bottom inset (`yl += ibottom`). Blessed's original was
          # `myl = items.length`; adding `ibottom` here as well double-counted
          # it, sizing a bordered shrink-to-content list one row too tall.
          myl = @items.size
        end
        if @top.nil? && !@bottom.nil?
          yi = yl - (myl - myi)
          yi -= itop
        else
          yl = myl
          yl += ibottom
        end
      end

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end

    # Returns minimum widget size based on content.
    #
    # NOTE: the widget must not have `#align=` set, or the alignment padding
    # will make the "minimal" size come out as the surrounding box's full size.
    def _minimal_content_rectangle(xi, xl, yi, yl)
      h = @_clines.size
      # `max_width` is `property max_width = 0` (Int32, never nil), so no `|| 0`.
      w = @_clines.max_width

      # The border box is sized to exactly the content (`w`/`h` + inner insets);
      # an outward margin shifts this box rather than shrinking it (see
      # `_get_coords`), so no margin room is reserved here.
      if @width.nil? && (@left.nil? || @right.nil?)
        if @left.nil? && !@right.nil?
          xi = xl - w - iwidth
        else
          xl = xi + w + iwidth
        end
      end
      # end

      if @height.nil? && (@top.nil? || @bottom.nil?) &&
         (!@scrollable || @_is_list)
        if @top.nil? && !@bottom.nil?
          yi = yl - h - iheight # (iheight == 1 ? 0 : iheight)
        else
          yl = yi + h + iheight # (iheight == 1 ? 0 : iheight)
        end
      end

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end

    # Frame memo for `_minimal_rectangle`: nested resizable widgets re-derive
    # the same subtree rectangle once per ancestor shrink pass plus their own
    # render — O(depth × subtree) per frame without this. Keyed on the exact
    # arguments plus `Window#renders`, so a moved/resized caller or a new frame
    # recomputes; `#mark_dirty` (content/geometry changes) clears it eagerly.
    @_minrect : Rectangle?
    @_minrect_key : Tuple(Int32, Int32, Int32, Int32, Bool, Int32)?

    # Drops the frame-memoized `_minimal_rectangle` result.
    def invalidate_minrect : Nil
      @_minrect = nil
    end

    # Returns minimum widget size
    def _minimal_rectangle(xi, xl, yi, yl, get)
      key = {xi, xl, yi, yl, get, window?.try(&.renders) || -1}
      if (r = @_minrect) && @_minrect_key == key
        return r
      end
      r = _minimal_rectangle_uncached(xi, xl, yi, yl, get)
      @_minrect = r
      @_minrect_key = key
      r
    end

    # :ditto: — the uncached computation.
    private def _minimal_rectangle_uncached(xi, xl, yi, yl, get)
      minimal_children_rectangle = _minimal_children_rectangle(xi, xl, yi, yl, get)
      minimal_content_rectangle = _minimal_content_rectangle(xi, xl, yi, yl)
      xll = xl
      yll = yl

      # Figure out which one is bigger and use it.
      if minimal_children_rectangle.xl - minimal_children_rectangle.xi > minimal_content_rectangle.xl - minimal_content_rectangle.xi
        xi = minimal_children_rectangle.xi
        xl = minimal_children_rectangle.xl
      else
        xi = minimal_content_rectangle.xi
        xl = minimal_content_rectangle.xl
      end

      if minimal_children_rectangle.yl - minimal_children_rectangle.yi > minimal_content_rectangle.yl - minimal_content_rectangle.yi
        yi = minimal_children_rectangle.yi
        yl = minimal_children_rectangle.yl
      else
        yi = minimal_content_rectangle.yi
        yl = minimal_content_rectangle.yl
      end

      # Recenter shrunken elements (matches `center`/`center±N` via
      # `center_expr?`): a shrunk widget pulled its origin back by half its
      # full width in `aleft`, so recentering by half the freed space is needed
      # to keep an offset-centered (`center+N`) widget from landing far off.
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

      Rectangle.new xi: xi, xl: xl, yi: yi, yl: yl
    end
  end
end
