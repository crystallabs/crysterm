require "pnggif"

module Crysterm
  class Widget
    module Graph
      # A small `QPainter`-style 2D rasterizer that draws into a `PNGGIF::Bitmap`
      # (RGBA pixels). Backend-agnostic: knows nothing about terminals, cells,
      # braille or sixel. `Graph::Canvas` allocates the bitmap at the native
      # resolution of whatever Media backend the terminal supports and hands it
      # here; the same paint code renders identically to braille, sixel, kitty, …
      #
      # Coordinates are logical. `#set_window` (logical bounds) and
      # `#set_viewport` (device-pixel bounds) define an affine logical→device
      # map, like `QPainter#setWindow`/`#setViewport`: declare your data space
      # once and draw resolution-independently. With no window set, logical
      # units equal device pixels.
      #
      # `#pen` is the stroke color (`0xRRGGBB`); `#pen_alpha` its opacity. X and Y
      # scale independently (so axis-aligned plots fill the viewport regardless of
      # the device's pixel aspect); `#draw_ellipse` additionally honors
      # `#pixel_aspect` so circles stay round on non-square backends.
      class Painter
        getter width : Int32
        getter height : Int32

        # Off-canvas magnitude for device coordinates. Non-finite or out-of-range
        # logical inputs map here — well outside any real bitmap, so `#plot`'s
        # bounds check rejects them — while staying far enough from Int32's limits
        # that downstream pixel arithmetic (marker/ellipse offsets, Bresenham
        # deltas) can't itself overflow.
        PX_LIMIT = 1_000_000
        # Device-radius cap for `#ellipse`: keeps the midpoint algorithm's squared
        # terms within Int64 and its iteration count bounded on pathological radii.
        ELLIPSE_R_MAX = 20_000

        # Stroke color as `0xRRGGBB`.
        @pen : Int32 = 0xFFFFFF

        def pen : Int32
          @pen
        end

        # Sets the stroke color, and recomputes `@pen_px` so the RGB unpack happens
        # once per stroke instead of once per plotted pixel.
        def pen=(v : Int32) : Int32
          @pen = v
          r, g, b = Media.rgb24(v)
          @pen_px = PNGGIF::Pixel.new(r, g, b, 255)
          v
        end

        # Stroke opacity, 0..255.
        @pen_alpha : UInt8 = 255_u8

        def pen_alpha : UInt8
          @pen_alpha
        end

        # Sets the stroke opacity, and recomputes the blend-invariant
        # `@pen_af`/`@pen_ia` factors so `#plot` doesn't redo the `/255.0`
        # division per pixel.
        def pen_alpha=(v : UInt8) : UInt8
          @pen_alpha = v
          @pen_af = v / 255.0
          @pen_ia = 1.0 - @pen_af
          v
        end

        # Pre-unpacked opaque pixel for the current `@pen`, written directly by
        # `#plot`'s opaque branch.
        @pen_px : PNGGIF::Pixel = PNGGIF::Pixel.new(255, 255, 255, 255)
        # Blend factor (`@pen_alpha / 255.0`) and its complement, for `#plot`'s
        # translucent branch.
        @pen_af : Float64 = 1.0
        @pen_ia : Float64 = 0.0

        # Physical width:height of one device pixel (1.0 = square). Used by
        # `#draw_ellipse` so an intended circle isn't squashed on backends whose
        # device pixels aren't square (block/quadrant/sextant).
        property pixel_aspect : Float64 = 1.0

        # Logical window (the coordinate space the caller draws in).
        @wx : Float64 = 0.0
        @wy : Float64 = 0.0
        @ww : Float64
        @wh : Float64

        # Device viewport (pixel rectangle the window maps onto).
        @vx : Float64 = 0.0
        @vy : Float64 = 0.0
        @vw : Float64
        @vh : Float64

        def initialize(@bmp : PNGGIF::Bitmap)
          @height = @bmp.size
          @width = @height > 0 ? @bmp[0].size : 0
          @ww = @vw = @width.to_f
          @wh = @vh = @height.to_f
        end

        # Sets the logical coordinate window (`QPainter#setWindow`): subsequent
        # draw calls are in these units. A zero extent is clamped to 1 to stay
        # invertible.
        def set_window(x : Number, y : Number, w : Number, h : Number) : Nil
          @wx, @wy = x.to_f, y.to_f
          @ww = w.to_f.zero? ? 1.0 : w.to_f
          @wh = h.to_f.zero? ? 1.0 : h.to_f
        end

        # `Rectangle` overload of `#set_window` (`QPainter#setWindow(QRect)`).
        def window=(r : Rectangle) : Nil
          set_window r.x, r.y, r.width, r.height
        end

        # Sets the device viewport in pixels (`QPainter#setViewport`). Defaults to
        # the whole bitmap.
        def set_viewport(x : Number, y : Number, w : Number, h : Number) : Nil
          @vx, @vy = x.to_f, y.to_f
          @vw, @vh = w.to_f, h.to_f
        end

        # `Rectangle` overload of `#set_viewport` (`QPainter#setViewport(QRect)`).
        def viewport=(r : Rectangle) : Nil
          set_viewport r.x, r.y, r.width, r.height
        end

        # Fills the whole bitmap with *color* (default fully transparent, since
        # translucent pixels leave the terminal untouched).
        def clear(color : Int32 = 0, alpha : UInt8 = 0_u8) : Nil
          r, g, b = Media.rgb24(color)
          px = PNGGIF::Pixel.new(r, g, b, alpha.to_i)
          @bmp.each &.fill(px)
        end

        # --- primitives (logical coords) ---------------------------------------

        def draw_point(x : Number, y : Number) : Nil
          plot dx(x), dy(y)
        end

        # Draws a small filled square marker (radius in *device pixels*) centered
        # on the logical point — a single pixel is too faint for scatter points.
        def draw_marker(x : Number, y : Number, radius : Int32 = 1) : Nil
          cx, cy = dx(x), dy(y)
          (-radius..radius).each do |oy|
            (-radius..radius).each { |ox| plot cx + ox, cy + oy }
          end
        end

        def draw_line(x0 : Number, y0 : Number, x1 : Number, y1 : Number) : Nil
          # A non-finite endpoint would map through `to_px` to the far-off-canvas
          # sentinel; unlike `#plot`'s per-pixel bounds check, `#line`'s Bresenham
          # walk plots every pixel *between* the endpoints, so a valid point to a
          # sentinel point draws a visible stray ray to the canvas edge and then
          # iterates ~10^6 rejected pixels off-canvas. Skip the segment entirely.
          return unless Crysterm.all_finite?(x0.to_f, y0.to_f, x1.to_f, y1.to_f)
          line dx(x0), dy(y0), dx(x1), dy(y1)
        end

        # Connects consecutive points with line segments.
        def draw_polyline(points : Array(Tuple(Float64, Float64))) : Nil
          return if points.size < 2
          (1...points.size).each do |i|
            a = points[i - 1]
            b = points[i]
            next unless Crysterm.all_finite?(a[0], a[1], b[0], b[1])
            line dx(a[0]), dy(a[1]), dx(b[0]), dy(b[1])
          end
        end

        # Outlines a rectangle (logical x,y = top-left; w,h = size).
        def draw_rect(x : Number, y : Number, w : Number, h : Number) : Nil
          # A non-finite coordinate/size maps through `to_px` to the far-off-canvas
          # sentinel, and — like `#draw_line`'s equivalent guard above — the
          # Bresenham `line` walk plots every pixel between a valid corner and
          # the sentinel: a visible stray full-height/width ray plus ~10^6
          # rejected off-canvas plots per edge. Skip the whole rect instead.
          return unless Crysterm.all_finite?(x.to_f, y.to_f, w.to_f, h.to_f)
          x0, y0, x1, y1 = dx(x), dy(y), dx(x + w), dy(y + h)
          line x0, y0, x1, y0
          line x1, y0, x1, y1
          line x1, y1, x0, y1
          line x0, y1, x0, y0
        end

        # Fills a rectangle solid.
        def fill_rect(x : Number, y : Number, w : Number, h : Number) : Nil
          x0, x1 = dx(x), dx(x + w)
          y0, y1 = dy(y), dy(y + h)
          x0, x1 = x1, x0 if x0 > x1
          y0, y1 = y1, y0 if y0 > y1
          # Clamp to the bitmap before iterating: `to_px` maps non-finite
          # coordinates to the far-off-canvas ±`PX_LIMIT` sentinel, and while
          # `#plot` rejects every such pixel, a NaN×NaN rect would still
          # *iterate* the full sentinel span (~10^12 plot calls, wedging the
          # render fiber). Off-canvas spans collapse to an empty loop instead.
          x0 = Math.max(x0, 0)
          y0 = Math.max(y0, 0)
          x1 = Math.min(x1, @width - 1)
          y1 = Math.min(y1, @height - 1)
          return if x0 > x1 || y0 > y1
          # Bounds are clamped above, so the per-pixel re-check and the
          # per-column re-lookup of `@bmp[py]` that `#plot` would do are both
          # redundant here; resolve the row once per scanline instead.
          (y0..y1).each do |py|
            row = @bmp[py]
            (x0..x1).each { |px| plot_in row, px }
          end
        end

        # Draws an axis-aligned ellipse outline centered at logical (cx, cy) with
        # logical radii (rx, ry). Radii map to device space; `#pixel_aspect`
        # corrects the vertical radius so an intended circle stays round on
        # non-square backends.
        def draw_ellipse(cx : Number, cy : Number, rx : Number, ry : Number) : Nil
          dcx, dcy = dx(cx), dy(cy)
          drx = (rx.to_f / @ww * @vw).abs
          dry = (ry.to_f / @wh * @vh).abs * @pixel_aspect
          # Cap the device radii: a non-finite radius maps to the negative sentinel
          # (rejected by `#ellipse`'s `a <= 0` guard), and a huge finite one is
          # bounded so the midpoint math and loop stay overflow-free and finite.
          ellipse dcx, dcy, Math.min(to_px(drx), ELLIPSE_R_MAX), Math.min(to_px(dry), ELLIPSE_R_MAX)
        end

        # Fills an annular sector (ring arc) in device pixels, centered at device
        # (cx, cy), between `r_inner`..`r_outer` radii, over `start_deg`..
        # `start_deg + sweep_deg`. `0°` is up (12 o'clock), angles increase
        # clockwise. Vertical radius is scaled by `#pixel_aspect` so the ring is
        # physically round on non-square backends. Works in device space, so the
        # geometry is independent of any window/viewport.
        def fill_ring(cx : Number, cy : Number, r_inner : Number, r_outer : Number,
                      start_deg : Number = 0.0, sweep_deg : Number = 360.0,
                      step_deg : Number = 0.7) : Nil
          ri = r_inner.to_f
          ro = r_outer.to_f
          # A non-finite radius (`Float64::INFINITY`, NaN, `-Inf`) passes the
          # `ro <= 0` guard but leaves the spoke loop `while r <= ro` unable to
          # terminate; a huge finite `ro` would iterate for ages. Bail on
          # non-finite radii and cap `ro` at `ELLIPSE_R_MAX` (as `#draw_ellipse`
          # does) so the loop count stays bounded.
          return unless Crysterm.all_finite?(ri, ro)
          return if ro <= 0
          ro = ELLIPSE_R_MAX.to_f if ro > ELLIPSE_R_MAX
          cxf = cx.to_f
          cyf = cy.to_f
          start = start_deg.to_f
          stop = start + sweep_deg.to_f
          # Degenerate/non-finite angles: NaN comparisons are always false, so a
          # NaN start/stop would spin the spoke loop forever (or crash on the
          # NaN→Int32 conversion in `plot`); a non-positive `step` never lets `a`
          # reach `stop`. Bail on non-finite angles and clamp step to the default.
          return unless Crysterm.all_finite?(start, stop)
          step = step_deg.to_f
          step = 0.7 if !step.finite? || step <= 0.0
          # Refine the angular step so adjacent spokes stay ≤ ~0.5 px apart at the
          # OUTER radius: at the 0.7° default the tangential spacing is
          # `ro · 0.0122` px, which exceeds 1 px for `ro ≳ 100` and shows radial
          # pinhole banding. Floored at 0.05° so a huge radius can't explode the
          # spoke count; the 0.5 px radial step already fills between rings.
          fine = (0.5 / ro) * 180.0 / Math::PI
          fine = 0.05 if fine < 0.05
          step = fine if step > fine
          a = start
          # Draw spokes at `start, start+step, …`, and always a final spoke at
          # exactly `stop` so the arc reaches its full extent instead of stopping
          # up to `step` short — which otherwise leaves a sliver open just
          # counter-clockwise of the end angle (the top-left, for a full ring).
          loop do
            ang = a < stop ? a : stop
            rad = (ang - 90.0) * Math::PI / 180.0
            ca = Math.cos rad
            sa = Math.sin(rad) * @pixel_aspect
            r = ri
            while r <= ro
              plot to_px(cxf + r * ca), to_px(cyf + r * sa)
              r += 0.5
            end
            break if a >= stop
            a += step
          end
        end

        # --- transform ---------------------------------------------------------

        # Converts a device-space float to an Int32 pixel coordinate. `Float64#to_i`
        # raises `OverflowError` on NaN/Infinity or out-of-Int32 values, which would
        # crash the render fiber; instead map non-finite values to an off-canvas
        # sentinel (rejected by `#plot`'s bounds check) and clamp finite ones. The
        # clamp bound (`PX_LIMIT`, not Int32::MAX) leaves headroom so callers can
        # add small offsets to the result without overflowing in turn.
        private def to_px(v : Float64) : Int32
          return -PX_LIMIT unless v.finite?
          v.clamp(-PX_LIMIT.to_f, PX_LIMIT.to_f).round.to_i
        end

        private def dx(lx : Number) : Int32
          to_px(@vx + (lx.to_f - @wx) / @ww * @vw)
        end

        private def dy(ly : Number) : Int32
          to_px(@vy + (ly.to_f - @wy) / @wh * @vh)
        end

        # --- device-space rasterization ----------------------------------------

        private def plot(x : Int32, y : Int32) : Nil
          return if x < 0 || y < 0 || x >= @width || y >= @height
          plot_in @bmp[y], x
        end

        # Writes one pixel into an already-resolved bitmap row. Callers that
        # have clamped `x`/`y` themselves (`#fill_rect`) hoist the row lookup out
        # of the inner loop and come here directly; scattered writers (`#line`,
        # `#four_way`, `#fill_ring`, `#draw_marker`) keep going through `#plot`.
        # Indexing stays **checked**: `#initialize` measures `@width` from
        # `@bmp[0].size` only, so a caller-supplied ragged bitmap must raise here
        # exactly as it did when `#plot` wrote `@bmp[y][x]` — never `unsafe_put`.
        private def plot_in(row : Array(PNGGIF::Pixel), x : Int32) : Nil
          if @pen_alpha >= 255
            row[x] = @pen_px
          else
            old = row[x]
            row[x] = PNGGIF::Pixel.new(
              (@pen_px.r * @pen_af + old.r * @pen_ia).round.to_i,
              (@pen_px.g * @pen_af + old.g * @pen_ia).round.to_i,
              (@pen_px.b * @pen_af + old.b * @pen_ia).round.to_i,
              Math.max(@pen_alpha.to_i, old.a))
          end
        end

        # Bresenham line.
        private def line(x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32) : Nil
          dx = (x1 - x0).abs
          dy = -(y1 - y0).abs
          sx = x0 < x1 ? 1 : -1
          sy = y0 < y1 ? 1 : -1
          err = dx + dy
          x, y = x0, y0
          loop do
            plot x, y
            break if x == x1 && y == y1
            e2 = 2 * err
            if e2 >= dy
              err += dy
              x += sx
            end
            if e2 <= dx
              err += dx
              y += sy
            end
          end
        end

        # Midpoint ellipse outline.
        private def ellipse(cx : Int32, cy : Int32, a : Int32, b : Int32) : Nil
          return if a <= 0 || b <= 0
          # Int64 for the squared terms: with `a`/`b` capped at ELLIPSE_R_MAX the
          # products (a2*b2 ~ R⁴) stay well within Int64, so no OverflowError.
          a2 = a.to_i64 * a
          b2 = b.to_i64 * b
          x = 0
          y = b
          # Region 1
          d1 = b2 - a2 * b + 0.25 * a2
          dx = 0_i64
          dy = 2_i64 * a2 * y
          while dx < dy
            four_way cx, cy, x, y
            if d1 < 0
              x += 1; dx += 2_i64 * b2; d1 += dx + b2
            else
              x += 1; y -= 1; dx += 2_i64 * b2; dy -= 2_i64 * a2; d1 += dx - dy + b2
            end
          end
          # Region 2
          d2 = b2 * (x + 0.5) * (x + 0.5) + a2 * (y - 1) * (y - 1) - a2 * b2
          while y >= 0
            four_way cx, cy, x, y
            if d2 > 0
              y -= 1; dy -= 2_i64 * a2; d2 += a2 - dy
            else
              y -= 1; x += 1; dx += 2_i64 * b2; dy -= 2_i64 * a2; d2 += dx - dy + a2
            end
          end
        end

        private def four_way(cx : Int32, cy : Int32, x : Int32, y : Int32) : Nil
          plot cx + x, cy + y
          plot cx - x, cy + y
          plot cx + x, cy - y
          plot cx - x, cy - y
        end
      end
    end
  end
end
