module Crysterm
  class Window
    # Occlusion: what this window paints over a widget — the counterpart of
    # Qt's clipping a native child (a `QWindow`, a video surface) to the
    # widgets stacked above it, while a `QMenu` pops up above everything.
    #
    # A picture the terminal keeps apart from the cells (a Kitty placement, an
    # external helper's window) or paints after them (sixel, iTerm2) would land
    # on top of whatever the frame drew over its rectangle: a menu, a torn-off
    # menu, a dialog, a tool tip. `Widget#visible_region` asks this walk for
    # the cells the widget still shows, and the media backends present only
    # those (`Media::Graphics#redraw_image`).
    #
    # Stacking follows paint order exactly as `#widget_at` does: the tree
    # depth first in `children` order, a container's `layout_chrome?` children
    # (border labels, bound scroll bars) after its other ones, and a subtree
    # with a `z_index` on the plane of its outermost one, above the base
    # layer. What paints after the widget, on its layer or a higher one, is
    # above it; the widget's own descendants are not (they are its content —
    # a background picture's owner's text and children included), nor its
    # ancestors, which paint before it.

    # Scratch state of one `#subtract_stacked_above` walk: the widget the walk
    # stacks against, its layer key, and whether the walk has passed it.
    @_occl_target : Widget? = nil
    @_occl_key : Tuple(Int32, Int32) = {0, 0}
    @_occl_passed = false
    @_occl_region = Region.new

    # *region* less the cells painted above *widget* this frame (see the
    # section comment): the rectangle each such widget painted — its `lpos`,
    # with its shadow's bands — minus nothing for a widget that fills no
    # background (`fill: false`), whose children are still taken. A widget
    # whose background picture layer (`Widget#layout_excluded?`) asks stacks
    # as its owner, the widget it is painted with.
    def subtract_stacked_above(widget : Widget, region : Region) : Region
      return region if region.empty?
      target = widget
      target = target.parent || target if target.layout_excluded?
      @_occl_target = target
      @_occl_key = stacking_key_of target
      @_occl_passed = false
      @_occl_region = region
      children.each { |el| occlusion_scan el, true, nil }
      @_occl_region
    ensure
      @_occl_target = nil
    end

    # The layer key of *w*, as `#hit_scan` ranks candidates: `{0, 0}` on the
    # base layer, `{1, z}` under an ancestor-or-self with `z_index` *z* that
    # opens a plane (the outermost one).
    private def stacking_key_of(w : Widget) : Tuple(Int32, Int32)
      z : Int32? = nil
      n = w
      while n
        if (zi = n.style.z_index) && !n.local_layer?
          z = zi
        end
        n = n.parent
      end
      z ? {1, z} : {0, 0}
    end

    # Visits *el* and its subtree in paint order (see the section comment),
    # subtracting from `@_occl_region` what paints above the target. An
    # invisible subtree paints nothing; a `layout_excluded?` child (a
    # background picture layer) paints with its owner, under the owner's
    # content, and covers nothing.
    private def occlusion_scan(el : Widget, anc_visible : Bool, anc_z : Int32?) : Nil
      return if @_occl_region.empty?
      visible = anc_visible && el.style.visible?
      return unless visible
      return if el.layout_excluded?
      if el.same?(@_occl_target)
        @_occl_passed = true
        return
      end
      z = anc_z || (el.local_layer? ? nil : el.style.z_index)
      key = z ? {1, z} : {0, 0}
      if (key > @_occl_key || (key == @_occl_key && @_occl_passed)) && el.style.fill?
        if lp = el.lpos
          rect = occluding_rect el, lp
          @_occl_region = @_occl_region.subtracted rect unless rect.empty?
        end
      end
      kids = el.children
      return if kids.empty?
      kids.each { |c| occlusion_scan c, visible, z unless c.layout_chrome? }
      kids.each { |c| occlusion_scan c, visible, z if c.layout_chrome? }
    end

    # The cells *el* paints at *lp*: its rectangle grown by its shadow's
    # extents, as the damage engine counts it (`#damage_widget_rect`).
    private def occluding_rect(el : Widget, lp : RenderedGeometry) : Rectangle
      xi, xl, yi, yl = lp.xi, lp.xl, lp.yi, lp.yl
      s = el.style.shadow_view
      if s.any?
        xi -= s.left
        xl += s.right
        yi -= s.top
        yl += s.bottom
      end
      Rectangle.of_edges xi, yi, xl, yl
    end
  end
end
