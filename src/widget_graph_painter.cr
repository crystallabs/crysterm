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
        property pen : Int32 = 0xFFFFFF
        # Stroke opacity, 0..255.
        property pen_alpha : UInt8 = 255_u8

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

        # Sets the device viewport in pixels (`QPainter#setViewport`). Defaults to
        # the whole bitmap.
        def set_viewport(x : Number, y : Number, w : Number, h : Number) : Nil
          @vx, @vy = x.to_f, y.to_f
          @vw, @vh = w.to_f, h.to_f
        end

        # Fills the whole bitmap with *color* (default fully transparent, since
        # translucent pixels leave the terminal untouched).
        def clear(color : Int32 = 0, alpha : UInt8 = 0_u8) : Nil
          r, g, b = Media.rgb24(color)
          px = PNGGIF::Pixel.new(r, g, b, alpha.to_i)
          @height.times { |y| @width.times { |x| @bmp[y][x] = px } }
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
          line dx(x0), dy(y0), dx(x1), dy(y1)
        end

        # Connects consecutive points with line segments.
        def draw_polyline(points : Array(Tuple(Float64, Float64))) : Nil
          return if points.size < 2
          (1...points.size).each do |i|
            a = points[i - 1]
            b = points[i]
            line dx(a[0]), dy(a[1]), dx(b[0]), dy(b[1])
          end
        end

        # Outlines a rectangle (logical x,y = top-left; w,h = size).
        def draw_rect(x : Number, y : Number, w : Number, h : Number) : Nil
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
          (y0..y1).each { |py| (x0..x1).each { |px| plot px, py } }
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
        # physically round on non-square backends. Used by `Graph::Donut`; works
        # in device space so geometry is independent of any window/viewport.
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
          return unless ri.finite? && ro.finite?
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
          return unless start.finite? && stop.finite?
          step = step_deg.to_f
          step = 0.7 if !step.finite? || step <= 0.0
          # Refine the angular step so adjacent spokes stay ≤ ~0.5 px apart at
          # the OUTER radius: with the fixed 0.7° default the tangential spoke
          # spacing is `ro · 0.0122` px, which exceeds 1 px for `ro ≳ 100` —
          # e.g. a sixel/Kitty donut at `ro ≈ 150` shows radial pinhole
          # banding. Floored at 0.05° so a huge radius can't explode the spoke
          # count (the 0.5 px radial step already fills between rings).
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
          r, g, b = Media.rgb24(@pen)
          if @pen_alpha >= 255
            @bmp[y][x] = PNGGIF::Pixel.new(r, g, b, 255)
          else
            old = @bmp[y][x]
            af = @pen_alpha / 255.0
            ia = 1.0 - af
            @bmp[y][x] = PNGGIF::Pixel.new(
              (r * af + old.r * ia).round.to_i,
              (g * af + old.g * ia).round.to_i,
              (b * af + old.b * ia).round.to_i,
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

      # Shared text-overlay helpers for the Canvas-backed graph widgets
      # (`LineChart`, `Donut`, `Map`). These graphs draw their plot/pixels on a
      # `Graph::Canvas` child, then stamp crisp terminal text (titles, axis
      # labels, markers, readouts) directly onto `window.lines` on top. This
      # module centralizes that stamping plus a small per-color attr memoizer.
      #
      # Including types are `Widget` subclasses, so `window`, `style` and
      # `sattr` are available.
      module TextOverlay
        # Memoized cell attrs, keyed on *both* the requested color and the
        # current `style.bg`, so a background change doesn't keep serving a stale
        # attr captured at first use. Bounded; see `Cache::GRAPH_ATTR_CAPACITY`.
        @attr_cache = Cache::Bounded(Tuple(Int32, Int32?), Int64).new(Cache::GRAPH_ATTR_CAPACITY)

        # Returns (and caches) the packed cell attr for *color* on the widget's
        # current background.
        private def overlay_attr(color : Int32) : Int64
          bg = style.bg
          @attr_cache.fetch({color, bg}) { sattr(style, color, bg) }
        end

        # Writes *text* starting at absolute cell (x, y), clipped to the
        # half-open column range `[lo, hi)` so labels never bleed past their
        # region.
        private def put_text(x : Int32, y : Int32, text : String, attr : Int64,
                             lo : Int32, hi : Int32) : Nil
          # A negative row wraps to the bottom of `window.lines` (Crystal's
          # Indexable indexes from the end); a negative `lo` (derived from
          # `@lpos.xi + ileft` when scrolled off-screen) can't clip and lets a
          # negative `cx` wrap to the right end of the row. Guard both so an
          # off-top/off-left label isn't stamped onto wrapped cells.
          return if y < 0
          lo = 0 if lo < 0
          line = window.lines[y]?
          return unless line
          text.each_char_with_index do |ch, i|
            cx = x + i
            next if cx < lo || cx >= hi
            if cell = line[cx]?
              cell.char = ch
              cell.attr = attr
            end
          end
          line.dirty = true
        end

        # Writes a single glyph *ch* at absolute cell (x, y), clipped to the
        # half-open column range `[lo, hi)`.
        private def put_cell(x : Int32, y : Int32, ch : Char, attr : Int64,
                             lo : Int32, hi : Int32) : Nil
          # See `#put_text`: guard the negative row (wraps to the bottom) and
          # clamp the clip floor so a negative `lo` still rejects off-left cells.
          return if y < 0
          lo = 0 if lo < 0
          return if x < lo || x >= hi
          line = window.lines[y]?
          return unless line
          if cell = line[x]?
            cell.char = ch
            cell.attr = attr
            line.dirty = true
          end
        end

        # Centers *text* within the column range `[xi, xl)` on row *y* (a thin
        # wrapper over `#put_text`). No-ops on an empty string.
        private def put_centered(text : String, xi : Int32, xl : Int32, y : Int32, attr : Int64) : Nil
          return if text.empty?
          x = xi + Math.max(0, (xl - xi - text.size) // 2)
          put_text x, y, text, attr, xi, xl
        end
      end

      # Shared center/radius geometry for the ring-based Canvas graphs
      # (`Donut`, `PieChart`): given a `Painter` sized to the device, returns the
      # `{cx, cy, ro}` of the largest physically-round circle that fits, or `nil`
      # when the surface is degenerate. Callers pass their own inner radius to
      # `Painter#fill_ring`, so this stays policy-free (no thickness knob here).
      module RingGeometry
        private def ring_geometry(p : Painter) : Tuple(Float64, Float64, Float64)?
          w = p.width
          h = p.height
          return nil if w <= 0 || h <= 0
          # True geometric center of the pixel span (`0..w-1`): `(w-1)/2`, not
          # `w//2`, which sits half a pixel low-and-right and skews the ring.
          cx = (w - 1) / 2.0
          cy = (h - 1) / 2.0
          # Largest physically-round radius that fits (vertical extent is scaled
          # by pixel_aspect), with a small margin.
          aspect = p.pixel_aspect
          ro = Math.min(w / 2.0, (h / 2.0) / (aspect <= 0 ? 1.0 : aspect)) * 0.92
          return nil if ro <= 1
          {cx, cy, ro}
        end
      end
    end
  end
end
