module Crysterm
  class Widget
    # Widget decorations

    # The `{ileft, itop, iright, ibottom}` inner insets, cached per frame. Each
    # getter otherwise resolves `#style` twice (border + padding), and they
    # fire many times per widget per frame: per auto-sized child (`awidth`'s nil
    # branch reads the parent's), ×4 per container in `Layout#interior_coords`,
    # and inside `_render`'s clip guards. Validity is tied to the frame-memoized
    # style: `#style` clears this on every (re)resolution, and
    # `#invalidate_frame_style` clears both.
    @_frame_insets : Tuple(Int32, Int32, Int32, Int32)?

    private def frame_insets : Tuple(Int32, Int32, Int32, Int32)
      # `#style` first: on a new frame (or after invalidation) it re-resolves
      # and resets `@_frame_insets`, so a surviving value is current.
      st = style
      if fi = @_frame_insets
        return fi
      end
      p = st.padding
      fi = if b = st.border
             {b.left + p.left, b.top + p.top, b.right + p.right, b.bottom + p.bottom}
           else
             {p.left, p.top, p.right, p.bottom}
           end
      @_frame_insets = fi
      fi
    end

    # Returns computed content offset from left
    def ileft
      frame_insets[0]
    end

    # Returns computed content offset from top
    def itop
      frame_insets[1]
    end

    # Returns computed content offset from right
    def iright
      frame_insets[2]
    end

    # Returns computed content offset from bottom
    def ibottom
      frame_insets[3]
    end

    # Returns summed amount of content offset from left and right
    def iwidth
      fi = frame_insets
      fi[0] + fi[2]
    end

    # Returns summed amount of content offset from top and bottom
    def iheight
      fi = frame_insets
      fi[1] + fi[3]
    end

    # This widget's **content rectangle** in absolute window coordinates: where
    # it last painted, inset by its border and padding (Qt's
    # `QWidget::contentsRect`). `nil` before the widget has a rendered position,
    # or when the insets leave nothing.
    #
    # This is the rectangle to map pointer coordinates against, and the one to
    # paint into. Both callers get the right frame for free:
    #
    # * from an `Event::Mouse` handler it is the last painted rectangle — the
    #   one the user actually clicked on;
    # * from inside `#render` it is this frame's, since `@lpos` is assigned
    #   before children (and any custom painting) run.
    #
    # ```
    # # Map a click to a cell of a fixed-width grid.
    # box.on(Event::Mouse) do |e|
    #   next unless (r = box.content_rect) && r.contains?(e.x, e.y)
    #   col = (e.x - r.xi) // CELL_W
    #   row = e.y - r.yi
    # end
    # ```
    #
    # Prefer this over hand-rolling `aleft(true) + ileft` / `awidth - iwidth`:
    # those mix the *rendered* and *live* geometry bases (`aleft(true)` reads the
    # last frame, bare `awidth` recomputes now), which disagree mid-resize.
    def content_rect : Rectangle?
      lp = @lpos || return nil
      xi = lp.xi + ileft
      xl = lp.xl - iright
      yi = lp.yi + itop
      yl = lp.yl - ibottom
      return nil if xl <= xi || yl <= yi
      Rectangle.new xi, xl, yi, yl
    end

    # Outer (margin) offsets. Counterpart to the inner `i*` offsets above,
    # applied to the resolved rectangle in `#_get_coords`. Used by
    # shrink-to-content sizing (`widget_size.cr`) so margin doesn't eat into a
    # shrunk widget's content.

    {% for side in %w[left top right bottom] %}
      # Margin offset on the {{side.id}} side
      def m{{side.id}}
        style.margin.{{side.id}}
      end
    {% end %}

    # Summed margin offset from left and right
    def mwidth
      m = style.margin
      m.left + m.right
    end

    # Summed margin offset from top and bottom
    def mheight
      m = style.margin
      m.top + m.bottom
    end
  end
end
