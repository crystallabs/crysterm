require "../box"
require "./canvas"
require "../../widget_graph_painter"
require "../../widget_graph_scale"

module Crysterm
  class Widget
    module Graph
      # A 2D heatmap: a matrix of `Float64` values rendered as a grid of colored
      # cells, one value per `(row, col)`, its color read off a `#colormap`.
      #
      # Each cell is drawn as a solid rectangle on a backend-agnostic
      # `Graph::Canvas` (sixel/kitty where available, else glyph cells). The
      # default `glyph_mode` is **block** rather than braille: a heatmap is a
      # grid of flat colors, so a block cell reads cleanly with no mid-cell color
      # bleed on the glyph fallback. A `NaN` cell is left transparent.
      #
      # A value `v` maps to a color by normalizing it to `t = (v - #minimum) /
      # (#maximum - #minimum)` (clamped to `0..1`) and indexing a 256-entry
      # color LUT precomputed from the `#colormap`. `#minimum`/`#maximum`
      # auto-compute from the finite data when left `nil`; `#symmetric` centers
      # a diverging map at `0`.
      #
      # With `#show_labels?` on (the default) `#col_labels`/`#row_labels` are
      # stamped across the top / down the left as terminal text; with
      # `#show_legend?` on a colorbar (a strip of the colormap with
      # `minimum`/`maximum` end labels) is stamped down the right. On hover the
      # cell under the pointer is emitted as `Event::CellHover` (row, col, value).
      #
      # ```
      # hm = Widget::Graph::HeatMap.new parent: s, width: 30, height: 14,
      #   values: [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], colormap: :viridis
      # hm.on(Crysterm::Event::CellHover) { |e| puts "#{e.row},#{e.col} = #{e.value}" }
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![HeatMap screenshot](../../../tests/widget/graph/heatmap/heatmap.5s.apng)
      # <!-- /widget-examples:capture -->
      class HeatMap < Box
        include TextOverlay
        include InteriorCoords
        include Mixin::CanvasOwner

        # One colormap stop: a normalized position `stop` (`0.0..1.0`) and its
        # color `rgb` (`0xRRGGBB`). Colors between stops are linearly
        # interpolated in RGB.
        record ColorStop, stop : Float64, rgb : Int32

        # Named colormaps, keyed by `Colormap`. `Grayscale` and the perceptual
        # `Viridis`/`Magma` are sequential; `Coolwarm` is diverging
        # (blue→white→red), best paired with `#symmetric`.
        enum Colormap
          Grayscale
          Viridis
          Magma
          Coolwarm
        end

        # Ordered color stops (first at `0.0`, last at `1.0`) per `Colormap`.
        COLORMAPS = {
          Colormap::Grayscale => [
            ColorStop.new(0.0, 0x000000), ColorStop.new(1.0, 0xFFFFFF),
          ],
          Colormap::Viridis => [
            ColorStop.new(0.0, 0x440154), ColorStop.new(0.25, 0x3B528B),
            ColorStop.new(0.5, 0x21908C), ColorStop.new(0.75, 0x5DC863),
            ColorStop.new(1.0, 0xFDE725),
          ],
          Colormap::Magma => [
            ColorStop.new(0.0, 0x000004), ColorStop.new(0.25, 0x3B0F70),
            ColorStop.new(0.5, 0x8C2981), ColorStop.new(0.75, 0xDE4968),
            ColorStop.new(1.0, 0xFCFDBF),
          ],
          Colormap::Coolwarm => [
            ColorStop.new(0.0, 0x3B4CC0), ColorStop.new(0.5, 0xF7F7F7),
            ColorStop.new(1.0, 0xB40426),
          ],
        }

        # Row-major matrix of values. A `NaN` cell renders transparent (missing).
        # Stored as `@matrix` (`Widget` already owns an unrelated `@data`).
        @matrix : Array(Array(Float64))

        def values : Array(Array(Float64))
          @matrix
        end

        # Labels stamped across the top (`col_labels`) and down the left
        # (`row_labels`). Empty by default; truncated to fit their region.
        getter col_labels : Array(String)
        getter row_labels : Array(String)

        # Explicit color-scale bounds. `nil` (the default) auto-computes each
        # from the finite data.
        getter minimum : Float64?
        getter maximum : Float64?

        # Whether to center a diverging map at `0`: the resolved bounds become
        # `±max(|lo|, |hi|)`, so `0` lands on the colormap's midpoint.
        getter? symmetric : Bool

        # The active colormap (a key of `COLORMAPS`).
        getter colormap : Colormap

        # Whether to draw the colorbar legend down the right edge.
        getter? show_legend : Bool

        # Whether to stamp the row/column axis labels.
        getter? show_labels : Bool

        # Overlay toggles: `#draw_legend`/`#draw_labels` stamp these over the
        # rendered widget (not the Canvas raster), so no `invalidate_canvas`; but
        # a plain `property?` setter schedules nothing and the toggle stays
        # invisible on an idle screen. `mark_dirty` registers damage and schedules
        # a frame.
        def show_legend=(v : Bool) : Bool
          return v if v == @show_legend
          @show_legend = v
          mark_dirty
          v
        end

        def show_labels=(v : Bool) : Bool
          return v if v == @show_labels
          @show_labels = v
          mark_dirty
          v
        end

        # 256-entry color LUT for the current `#colormap` (`t*255 -> 0xRRGGBB`),
        # so the paint loop never does per-cell float interpolation. Must be
        # dropped when `#colormap` changes.
        @lut : Array(Int32)?

        # Resolved `{minimum, maximum}` for the current data/bounds/`#symmetric`, so
        # repeated `#color_for` calls don't re-scan the matrix. Must be dropped
        # when the data or any bound-affecting property changes.
        @bounds : Tuple(Float64, Float64)?

        # The last hovered cell, so `Event::CellHover` fires only on a change.
        @hover_cell : Tuple(Int32, Int32)?

        def initialize(
          values : Array(Array(Float64)) = [] of Array(Float64),
          minimum : Float64? = nil,
          maximum : Float64? = nil,
          colormap : Colormap = Colormap::Viridis,
          col_labels : Array(String) = [] of String,
          row_labels : Array(String) = [] of String,
          @symmetric : Bool = false,
          @show_legend : Bool = true,
          @show_labels : Bool = true,
          type : Media::Type? = nil,
          glyph_mode : Media::Glyph::Mode = Media::Glyph::Mode::Block,
          **box,
        )
          @matrix = values.dup
          @col_labels = col_labels.dup
          @row_labels = row_labels.dup
          @minimum = minimum
          @maximum = maximum
          @colormap = colormap
          super **box

          build_canvas(type, glyph_mode) { |p| paint_grid p }

          # Map hovering onto the grid and re-emit as `Event::CellHover`.
          # Subscribing also makes this widget mouse-hit-testable.
          on(Crysterm::Event::MouseEnter) { |e| handle_hover e }
          on(Crysterm::Event::MouseMove) { |e| handle_hover e }
          on(Crysterm::Event::MouseLeave) { @hover_cell = nil }
        end

        # Replaces the whole matrix. Repaints and re-resolves the auto bounds.
        def values=(values : Array(Array(Float64))) : Array(Array(Float64))
          @matrix = values.dup
          @bounds = nil
          invalidate_canvas
          @matrix
        end

        def col_labels=(labels : Array(String)) : Array(String)
          @col_labels = labels.dup
          invalidate_canvas
          @col_labels
        end

        def row_labels=(labels : Array(String)) : Array(String)
          @row_labels = labels.dup
          invalidate_canvas
          @row_labels
        end

        # Sets the lower scale bound (`nil` re-enables auto). Rebuilds the
        # resolved bounds and repaints.
        def minimum=(v : Float64?) : Float64?
          @minimum = v
          @bounds = nil
          invalidate_canvas
          @minimum
        end

        def maximum=(v : Float64?) : Float64?
          @maximum = v
          @bounds = nil
          invalidate_canvas
          @maximum
        end

        def symmetric=(v : Bool) : Bool
          @symmetric = v
          @bounds = nil
          invalidate_canvas
          @symmetric
        end

        # Switches the colormap. Drops the LUT so the next paint rebuilds it,
        # then repaints.
        def colormap=(name : Colormap) : Colormap
          @colormap = name
          @lut = nil
          invalidate_canvas
          @colormap
        end

        def render(with_children = true)
          super
          draw_labels
          draw_legend
        end

        # The resolved `{minimum, maximum}` color-scale bounds for the current
        # data — explicit `#minimum`/`#maximum` where set, else the finite-data
        # range, with `#symmetric` centering and a `maximum == minimum` guard
        # applied.
        def value_range : Tuple(Float64, Float64)
          resolved_bounds
        end

        # The `0xRRGGBB` color for value *v* under the current colormap and
        # resolved bounds: normalize to `t`, then index the precomputed LUT.
        def color_for(v : Float64) : Int32
          lo, hi = resolved_bounds
          t = ((v - lo) / (hi - lo)).clamp(0.0, 1.0)
          # A NaN `t` (e.g. `0/0` from a degenerate scale) would make
          # `(t * 255).round.to_i` raise OverflowError.
          t = 0.0 unless t.finite?
          lut[(t * 255).round.to_i]
        end

        # The (lazily built) LUT for the active colormap.
        private def lut : Array(Int32)
          @lut ||= build_lut
        end

        # Precomputes a 256-entry `t*255 -> color` table by sampling the colormap
        # stops at `t = i/255`. `t = 0`/`1` land exactly on the first/last stop's
        # color, so `#color_for(minimum)`/`#color_for(maximum)` reproduce the endpoints.
        private def build_lut : Array(Int32)
          stops = COLORMAPS[@colormap]
          Array(Int32).new(256) { |i| sample_stops stops, i / 255.0 }
        end

        # Interpolates the colormap *stops* at normalized position *t* by linear
        # RGB lerp between the bracketing stops.
        private def sample_stops(stops : Array(ColorStop), t : Float64) : Int32
          return stops.first.rgb if t <= stops.first.stop
          return stops.last.rgb if t >= stops.last.stop
          i = 0
          while i < stops.size - 1 && t > stops[i + 1].stop
            i += 1
          end
          a = stops[i]
          b = stops[i + 1]
          span = b.stop - a.stop
          frac = span <= 0 ? 0.0 : (t - a.stop) / span
          # `Colors.mix(c1, c2, alpha)` weights `c1` by `alpha`; a `frac` of `0`
          # keeps stop `a`, `1` keeps stop `b` — hence `1.0 - frac`.
          Colors.mix a.rgb, b.rgb, 1.0 - frac
        end

        # Resolves (and caches) the `{minimum, maximum}` bounds. `nil` bounds
        # fall back to the finite-data range; `#symmetric` recenters on `0`; a
        # degenerate `maximum <= minimum` (all-equal or single value) is
        # widened by `1` so normalization stays finite.
        private def resolved_bounds : Tuple(Float64, Float64)
          if b = @bounds
            return b
          end
          lo = @minimum
          hi = @maximum
          # A non-finite *explicit* bound (e.g. `maximum = data.max` where the
          # data contains an Infinity) would poison the scale and crash the
          # render fiber; drop it so it falls back to the finite data range
          # like `nil`.
          lo = nil unless lo.nil? || lo.finite?
          hi = nil unless hi.nil? || hi.finite?
          if lo.nil? || hi.nil?
            dmin = nil.as(Float64?)
            dmax = nil.as(Float64?)
            @matrix.each do |row|
              row.each do |v|
                next unless v.finite?
                dmin = v if (d = dmin).nil? || v < d
                dmax = v if (d = dmax).nil? || v > d
              end
            end
            lo ||= dmin || 0.0
            hi ||= dmax || 1.0
          end
          if @symmetric
            m = Math.max(lo.abs, hi.abs)
            lo, hi = -m, m
          end
          hi = lo + 1.0 if hi <= lo
          @bounds = {lo, hi}
        end

        # Grid pass: map the logical `cols × rows` space onto the whole canvas
        # and fill each finite cell with its color. Ragged rows are tolerated;
        # `NaN` cells are left transparent.
        private def paint_grid(p : Painter) : Nil
          d = @matrix
          rows = d.size
          return if rows == 0
          cols = d[0].size
          return if cols == 0
          p.set_window 0, 0, cols, rows
          rows.times do |r|
            row = d[r]
            cols.times do |c|
              next if c >= row.size
              v = row[c]
              next if v.nan?
              p.pen = color_for(v)
              p.fill_rect c, r, 1, 1
            end
          end
        end

        # Stamps the row/column axis labels over the grid edges, clipped to the
        # interior. Column labels centered under-ish the top row; row labels
        # left-aligned down the first column. Both truncate to fit.
        private def draw_labels : Nil
          return unless show_labels?
          d = @matrix
          rows = d.size
          return if rows == 0
          cols = d[0].size
          return if cols == 0
          xi, xl, yi, yl = interior_coords || return
          return if xl - xi <= 0 || yl - yi <= 0
          text_attr = style_to_attr(style, style.fg, style.bg)

          # Column labels across the top row, each centered in its cell column.
          unless @col_labels.empty?
            cw = (xl - xi) / cols.to_f
            @col_labels.each_with_index do |label, c|
              break if c >= cols
              cxl = xi + (c * cw).to_i
              cxr = xi + ((c + 1) * cw).to_i
              put_centered label, cxl, Math.min(cxr, xl), yi, text_attr
            end
          end

          # Row labels down the left column, one per grid row.
          unless @row_labels.empty?
            rh = (yl - yi) / rows.to_f
            @row_labels.each_with_index do |label, r|
              break if r >= rows
              y = yi + (r * rh + rh / 2).to_i
              break if y >= yl
              put_text xi, y, label, text_attr, xi, xl
            end
          end
        end

        # Stamps the colorbar down the right edge: one cell per row from
        # `maximum` (top) to `minimum` (bottom) in the colormap's colors, with
        # numeric end labels to its left. Uses colored cells, not a second
        # paint pass.
        private def draw_legend : Nil
          return unless show_legend?
          xi, xl, yi, yl = interior_coords || return
          return if xl - xi <= 2 || yl - yi <= 1

          lo, hi = resolved_bounds
          bar_x = xl - 1
          span = (yl - 1 - yi).to_f
          (yi...yl).each do |y|
            # Top row is `t = 1` (maximum), bottom is `t = 0` (minimum).
            t = span <= 0 ? 1.0 : 1.0 - (y - yi) / span
            put_cell bar_x, y, Scale::FULL, overlay_attr(lut[(t * 255).round.to_i]), xi, xl
          end

          # Numeric end labels, right-aligned just left of the bar.
          text_attr = style_to_attr(style, style.fg, style.bg)
          hi_s = Scale.fmt hi
          lo_s = Scale.fmt lo
          put_text Math.max(xi, bar_x - hi_s.size), yi, hi_s, text_attr, xi, bar_x
          put_text Math.max(xi, bar_x - lo_s.size), yl - 1, lo_s, text_attr, xi, bar_x
        end

        # Emits `Event::CellHover` for the grid cell under the pointer, but only
        # when it differs from the last-hovered cell (avoids event spam on
        # motion).
        private def handle_hover(e : Crysterm::Event::Mouse) : Nil
          rc = cell_at e.x, e.y
          return if rc == @hover_cell
          @hover_cell = rc
          return unless rc
          row, col = rc
          v = @matrix[row]?.try &.[col]?
          return unless v
          emit Crysterm::Event::CellHover, row, col, v
        end

        # Maps an absolute cell (*x*, *y*) back to a `{row, col}` in the grid, or
        # `nil` when outside the interior or the data is empty. Must stay the
        # inverse of the `paint_grid` mapping.
        private def cell_at(x : Int32, y : Int32) : Tuple(Int32, Int32)?
          d = @matrix
          rows = d.size
          return if rows == 0
          cols = d[0].size
          return if cols == 0
          xi, xl, yi, yl = interior_coords || return
          return if xl <= xi || yl <= yi
          return if x < xi || x >= xl || y < yi || y >= yl
          col = ((x - xi) * cols) // (xl - xi)
          row = ((y - yi) * rows) // (yl - yi)
          {row.clamp(0, rows - 1), col.clamp(0, cols - 1)}
        end
      end
    end
  end
end
