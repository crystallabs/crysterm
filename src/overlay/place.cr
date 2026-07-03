module Crysterm
  module Overlay
    # Fit-based auto-placement for a floating overlay (drop-down list, pop-up
    # menu, completer list, submenu).
    #
    # Every overlay owner otherwise hand-rolled its own "place a rectangle next
    # to an anchor, flip/clamp on overflow" math, and the copies had drifted on
    # coordinate conventions (some subtracting the window inset, some not) and on
    # flip policy (below-only vs. flip-above vs. clamp-only). This function
    # replaces the *policy* with a declarative one: the caller supplies an
    # ordered list of `Side`s it *prefers*, and the placer returns the first
    # candidate that fully fits inside `bounds`; if none fits, it falls back to
    # the candidate with the most visible area and clamps that into `bounds`.
    #
    # ### Coordinate convention (the invariant that keeps callers consistent)
    #
    # Everything here is in **absolute screen coordinates** — `anchor`, `bounds`,
    # `point`, and the returned top-left. A caller whose overlay is a
    # *window-appended* child (whose `left`/`top` are relative to the window's
    # content origin, i.e. `aleft == window.ileft + left`) converts the result
    # once, uniformly:
    #
    # ```
    # x, y = Overlay.place(...)
    # child.left = x - window.ileft
    # child.top = y - window.itop
    # ```
    #
    # That single conversion is what a padded/bordered window needs; applying it
    # uniformly is why the placer can serve every owner without per-site inset
    # divergence.

    # Where to place the overlay relative to its anchor. Listed in a caller's
    # `prefer` order; the first that fits wins.
    enum Side
      Below # top-left at (anchor.x, anchor.y + anchor.h)
      Above # top-left at (anchor.x, anchor.y - size.h)
      Right # top-left at (anchor.x + anchor.w, anchor.y)
      Left  # top-left at (anchor.x - size.w, anchor.y)
      At    # top-left at an explicit `point` (e.g. the mouse cursor)
    end

    # Returns the absolute top-left `{x, y}` for a `size`-sized overlay placed
    # against `anchor`, within `bounds`.
    #
    # - *anchor* — `{x, y, w, h}`, absolute, the widget the overlay hangs off.
    # - *size*   — `{w, h}`, the overlay's outer size (including its border).
    # - *bounds* — `{x, y, w, h}`, absolute, the area the overlay must stay in
    #   (typically the window's content box).
    # - *prefer* — candidate `Side`s in priority order. The first whose full rect
    #   fits inside *bounds* is returned as-is. Empty is treated as `[Below]`.
    # - *point*  — required when `Side::At` is among *prefer*; the explicit
    #   top-left for that candidate. Ignored otherwise.
    #
    # When no candidate fits (the overlay is larger than the space on every
    # preferred side), the candidate with the largest visible area is chosen and
    # clamped into *bounds*, so the overlay stays as on-screen as possible rather
    # than spilling off an edge. When the overlay is larger than *bounds* itself,
    # it is pinned to the *bounds* origin on the overflowing axis.
    def self.place(anchor : Tuple(Int32, Int32, Int32, Int32),
                   size : Tuple(Int32, Int32),
                   bounds : Tuple(Int32, Int32, Int32, Int32),
                   prefer : Array(Side),
                   point : Tuple(Int32, Int32)? = nil) : Tuple(Int32, Int32)
      prefer = [Side::Below] if prefer.empty?
      w, h = size

      # First side whose full rect fits inside bounds.
      prefer.each do |side|
        c = candidate(side, anchor, w, h, point)
        return c if fits?(c, w, h, bounds)
      end

      # Nothing fit: fall back to the candidate that keeps the most of the
      # overlay visible, then clamp it into bounds.
      best = prefer.first
      best_area = -1
      prefer.each do |side|
        c = candidate(side, anchor, w, h, point)
        a = visible_area(c, w, h, bounds)
        if a > best_area
          best_area = a
          best = side
        end
      end
      clamp(candidate(best, anchor, w, h, point), w, h, bounds)
    end

    # Adoption helper: places *child* — a window-appended overlay — against
    # *anchor* and assigns its `left`/`top`, owning the single
    # absolute→window-local conversion so no call site repeats or forgets it
    # (the omission that mis-placed the combo popup on a bordered window).
    #
    # - *child*  — the overlay (a top-level child appended to its `window`).
    # - *anchor* — an absolute `{x, y, w, h}` rect. Build it from a widget with
    #   `{w.aleft, w.atop, w.awidth, w.aheight}`, or from a computed row rect for
    #   a submenu.
    # - *size*   — the child's outer `{w, h}`. The caller sizes the child first
    #   (row count, border) — that logic is legitimately per-overlay; the helper
    #   only positions.
    #
    # See `.place` for *prefer*/*point*. The bounds are the window's absolute
    # content box; a `Window` sits at the screen origin, so `aleft == ileft +
    # left`, hence the result converts back by subtracting the window insets.
    def self.place_child(child : Widget,
                         anchor : Tuple(Int32, Int32, Int32, Int32),
                         size : Tuple(Int32, Int32),
                         prefer : Array(Side),
                         point : Tuple(Int32, Int32)? = nil) : Nil
      win = child.window
      bounds = {win.ileft, win.itop, win.awidth - win.iwidth, win.aheight - win.iheight}
      x, y = place(anchor, size, bounds, prefer, point)
      child.left = x - win.ileft
      child.top = y - win.itop
    end

    # :nodoc:
    private def self.candidate(side : Side,
                               anchor : Tuple(Int32, Int32, Int32, Int32),
                               w : Int32, h : Int32,
                               point : Tuple(Int32, Int32)?) : Tuple(Int32, Int32)
      ax, ay, aw, ah = anchor
      case side
      in Side::Below then {ax, ay + ah}
      in Side::Above then {ax, ay - h}
      in Side::Right then {ax + aw, ay}
      in Side::Left  then {ax - w, ay}
      in Side::At    then point || {ax, ay}
      end
    end

    # :nodoc:
    private def self.fits?(c : Tuple(Int32, Int32), w : Int32, h : Int32,
                           bounds : Tuple(Int32, Int32, Int32, Int32)) : Bool
      cx, cy = c
      bx, by, bw, bh = bounds
      cx >= bx && cy >= by && cx + w <= bx + bw && cy + h <= by + bh
    end

    # :nodoc:
    # Area of the intersection of the candidate rect with *bounds* — how much of
    # the overlay would be visible if placed here without clamping.
    private def self.visible_area(c : Tuple(Int32, Int32), w : Int32, h : Int32,
                                  bounds : Tuple(Int32, Int32, Int32, Int32)) : Int32
      cx, cy = c
      bx, by, bw, bh = bounds
      iw = Math.min(cx + w, bx + bw) - Math.max(cx, bx)
      ih = Math.min(cy + h, by + bh) - Math.max(cy, by)
      Math.max(0, iw) * Math.max(0, ih)
    end

    # :nodoc:
    private def self.clamp(c : Tuple(Int32, Int32), w : Int32, h : Int32,
                           bounds : Tuple(Int32, Int32, Int32, Int32)) : Tuple(Int32, Int32)
      cx, cy = c
      bx, by, bw, bh = bounds
      # `Math.max(bx, ...)` guards the overlay-larger-than-bounds case: the upper
      # clamp bound would fall below `bx`, so pin to the bounds origin instead.
      x = cx.clamp(bx, Math.max(bx, bx + bw - w))
      y = cy.clamp(by, Math.max(by, by + bh - h))
      {x, y}
    end
  end
end
