module Crysterm
  class Widget
    # Captures this widget's on-screen region via `Screen#capture` (the single
    # capture entry point), auto-selecting the area the widget occupies in the
    # screen's rendered content. All of `Screen#capture`'s options are forwarded
    # (`format`, `path`, `duration`, `fps`, `loops`, …); returns its result, or
    # `nil` if the widget hasn't been rendered yet (no known position).
    #
    # By default the whole widget box (including decorations) is captured; pass
    # `include_decorations: false` for the content area only. `d*` deltas
    # grow/shrink the region per edge in cells.
    #
    # ```
    # widget.capture path: "widget.png"
    # widget.capture format: "gif", duration: 2.seconds
    # ```
    def capture(include_decorations = true, dxi = 0, dxl = 0, dyi = 0, dyl = 0, **opts) : Bytes?
      lpos = @lpos
      return unless lpos

      xi = lpos.xi + (include_decorations ? 0 : ileft) + dxi
      xl = lpos.xl + (include_decorations ? 0 : -iright) + dxl
      yi = lpos.yi + (include_decorations ? 0 : itop) + dyi
      yl = lpos.yl + (include_decorations ? 0 : -ibottom) + dyl

      screen.capture(xi, xl, yi, yl, **opts)
    end
  end
end
