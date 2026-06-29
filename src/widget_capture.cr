module Crysterm
  class Widget
    # Captures this widget's on-window region via `Window#capture` (the single
    # capture entry point), auto-selecting the area the widget occupies in the
    # window's rendered content. All of `Window#capture`'s options are forwarded
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

      window.capture(xi, xl, yi, yl, **opts)
    end

    # Text counterpart to `Widget#capture`: dumps just this widget's on-window
    # region via `Window#dump`, auto-selecting the area the widget occupies.
    # Mirrors `#capture` exactly (same `include_decorations` + per-edge `d*`
    # deltas, same forwarding of `Window#dump`'s options); returns the dump text,
    # or `nil` if the widget hasn't been rendered yet (no known position).
    #
    # ```
    # widget.dump                # -> String
    # widget.dump path: "w.dump" # writes the file
    # widget.dump include_decorations: false
    # ```
    def dump(include_decorations = true, dxi = 0, dxl = 0, dyi = 0, dyl = 0, **opts) : String?
      lpos = @lpos
      return unless lpos

      xi = lpos.xi + (include_decorations ? 0 : ileft) + dxi
      xl = lpos.xl + (include_decorations ? 0 : -iright) + dxl
      yi = lpos.yi + (include_decorations ? 0 : itop) + dyi
      yl = lpos.yl + (include_decorations ? 0 : -ibottom) + dyl

      window.dump(xi, xl, yi, yl, **opts)
    end
  end
end
