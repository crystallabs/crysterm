module Crysterm
  class Widget
    # Widget decorations

    # The `{ileft, itop, iright, ibottom}` inner insets, cached per frame: the
    # getters fire many times per widget per frame and each would otherwise
    # resolve `#style` twice (border + padding). Validity is tied to the
    # frame-memoized style, which clears this on every (re)resolution.
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
    def ileft : Int32
      frame_insets[0]
    end

    # Returns computed content offset from top
    def itop : Int32
      frame_insets[1]
    end

    # Returns computed content offset from right
    def iright : Int32
      frame_insets[2]
    end

    # Returns computed content offset from bottom
    def ibottom : Int32
      frame_insets[3]
    end

    # Total horizontal inset: `ileft + iright`. **Not** an inner width — the
    # content width is `awidth - ihorizontal`.
    def ihorizontal : Int32
      fi = frame_insets
      fi[0] + fi[2]
    end

    # Total vertical inset: `itop + ibottom`. **Not** an inner height — the
    # content height is `aheight - ivertical`.
    def ivertical : Int32
      fi = frame_insets
      fi[1] + fi[3]
    end

    # `#ileft`/`#itop`/`#iright`/`#ibottom` bundled into one value — Qt's
    # `QWidget::contentsMargins()`. A fresh `Padding` (never a shared
    # singleton), safe for the caller to hold onto past the current frame.
    def contents_margins : Padding
      fi = frame_insets
      Padding.new fi[0], fi[1], fi[2], fi[3]
    end

    # This widget's **content rectangle** in absolute window coordinates: where
    # it last painted, inset by its border and padding (Qt's
    # `QWidget::contentsRect`). `nil` before the widget has a rendered position,
    # or when the insets leave nothing.
    #
    # This is the rectangle to map pointer coordinates against, and the one to
    # paint into. Both callers get the right frame for free:
    #
    # * from an `Event::Mouse` handler it is the last painted rectangle — the one
    #   the user actually clicked on;
    # * from inside `#render` it is this frame's, since `@lpos` is assigned before
    #   children (and any custom painting) run.
    #
    # ```
    # # Map a click to a cell of a fixed-width grid.
    # box.on(Event::Mouse) do |e|
    #   next unless (r = box.contents_rect) && r.contains?(e.x, e.y)
    #   col = (e.x - r.left) // CELL_W
    #   row = e.y - r.top
    # end
    # ```
    #
    # Prefer this over hand-rolling `aleft(true) + ileft` / `awidth - ihorizontal`:
    # those mix the *rendered* and *live* geometry bases (`aleft(true)` reads the
    # last frame, bare `awidth` recomputes now), which disagree mid-resize.
    def contents_rect : Rectangle?
      lp = @lpos || return
      xi = lp.xi + ileft
      xl = lp.xl - iright
      yi = lp.yi + itop
      yl = lp.yl - ibottom
      return if xl <= xi || yl <= yi
      Rectangle.of_edges xi, yi, xl, yl
    end

    # Outer (margin) offsets — counterpart to the inner `i*` offsets above,
    # applied to the resolved rectangle in `#coords`.

    {% for side in %w[left top right bottom] %}
      # Margin offset on the {{ side.id }} side
      def m{{ side.id }} : Int32
        style.margin.{{ side.id }}
      end
    {% end %}

    # Total horizontal margin: `mleft + mright`. **Not** a width; see
    # `#ihorizontal`.
    def mhorizontal : Int32
      m = style.margin
      m.left + m.right
    end

    # Total vertical margin: `mtop + mbottom`. **Not** a height; see
    # `#ivertical`.
    def mvertical : Int32
      m = style.margin
      m.top + m.bottom
    end

    # `#mleft`/`#mtop`/`#mright`/`#mbottom` bundled into one value — the
    # resolved `Style#margin` itself, already the sided box these read from.
    def margins : Margin
      style.margin
    end
  end
end
