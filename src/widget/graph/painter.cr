require "pnggif"

module Crysterm
  class Widget
    module Graph
      # A small `QPainter`-style 2D rasterizer that draws into a `PNGGIF::Bitmap`
      # (RGBA pixels). It is deliberately **backend-agnostic**: it knows nothing
      # about terminals, cells, braille or sixel. `Graph::Canvas` allocates the
      # bitmap at the native resolution of whatever Media backend the terminal
      # was detected to support and hands it here; the same paint code then
      # renders identically to braille, sixel, kitty, …
      #
      # Coordinates are **logical**. `#set_window` (logical bounds) and
      # `#set_viewport` (device-pixel bounds) define an affine logical→device map,
      # exactly like `QPainter#setWindow`/`#setViewport`: declare your data space
      # once and draw in those units, resolution-independently. With no window set,
      # logical units equal device pixels.
      #
      # `#pen` is the stroke color (`0xRRGGBB`); `#pen_alpha` its opacity. X and Y
      # scale independently (so axis-aligned plots fill the viewport regardless of
      # the device's pixel aspect); `#draw_ellipse` additionally honors
      # `#pixel_aspect` so circles stay round on non-square backends.
      class Painter
        getter width : Int32
        getter height : Int32

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

        # Fills the whole bitmap with *color* (default fully transparent, the
        # natural "clear" since translucent pixels leave the terminal untouched).
        def clear(color : Int32 = 0, alpha : UInt8 = 0_u8) : Nil
          px = PNGGIF::Pixel.new((color >> 16) & 0xff, (color >> 8) & 0xff, color & 0xff, alpha.to_i)
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
          ellipse dcx, dcy, drx.round.to_i, dry.round.to_i
        end

        # --- transform ---------------------------------------------------------

        private def dx(lx : Number) : Int32
          (@vx + (lx.to_f - @wx) / @ww * @vw).round.to_i
        end

        private def dy(ly : Number) : Int32
          (@vy + (ly.to_f - @wy) / @wh * @vh).round.to_i
        end

        # --- device-space rasterization ----------------------------------------

        private def plot(x : Int32, y : Int32) : Nil
          return if x < 0 || y < 0 || x >= @width || y >= @height
          r = (@pen >> 16) & 0xff
          g = (@pen >> 8) & 0xff
          b = @pen & 0xff
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
          a2 = a * a
          b2 = b * b
          x = 0
          y = b
          # Region 1
          d1 = b2 - a2 * b + 0.25 * a2
          dx = 0
          dy = 2 * a2 * y
          while dx < dy
            four_way cx, cy, x, y
            if d1 < 0
              x += 1; dx += 2 * b2; d1 += dx + b2
            else
              x += 1; y -= 1; dx += 2 * b2; dy -= 2 * a2; d1 += dx - dy + b2
            end
          end
          # Region 2
          d2 = b2 * (x + 0.5) * (x + 0.5) + a2 * (y - 1) * (y - 1) - a2 * b2
          while y >= 0
            four_way cx, cy, x, y
            if d2 > 0
              y -= 1; dy -= 2 * a2; d2 += a2 - dy
            else
              y -= 1; x += 1; dx += 2 * b2; dy -= 2 * a2; d2 += dx - dy + a2
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
