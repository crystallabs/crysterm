require "../box"
require "./canvas"
require "../../widget_graph_painter"
require "../../widget_graph_scale"

module Crysterm
  class Widget
    module Graph
      # A 2D heatmap: a matrix of `Float64` values rendered as a grid of colored
      # cells, in the spirit of matplotlib's `imshow` / Qt's `QGraphicsScene`
      # image tiles. A grid sibling of `Graph::PieChart`/`Graph::Donut` (not a
      # subclass): a pie shows one value per category, a heatmap shows one value
      # per `(row, col)` cell, its color read off a `#colormap`.
      #
      # Each cell is drawn as a solid rectangle on a backend-agnostic
      # `Graph::Canvas` (sixel/kitty where available, else glyph cells) with
      # `Painter#fill_rect`; the default `glyph_mode` is **block** (one solid
      # color per terminal cell), not braille — a heatmap is a grid of flat
      # colors, so a block cell reads cleanly with no mid-cell color bleed on the
      # glyph fallback. A `NaN` cell is left transparent (missing data).
      #
      # A value `v` maps to a color by normalizing it to `t = (v - #vmin) /
      # (#vmax - #vmin)` (clamped to `0..1`) and indexing a 256-entry color LUT
      # precomputed from the `#colormap`. `#vmin`/`#vmax` auto-compute from the
      # finite data when left `nil`; `#symmetric` centers a diverging map at `0`.
      #
      # With `#show_labels?` on (the default) `#col_labels`/`#row_labels` are
      # stamped across the top / down the left as terminal text; with
      # `#show_legend?` on a colorbar (a strip of the colormap with `vmin`/`vmax`
      # end labels) is stamped down the right. On hover the cell under the
      # pointer is emitted as `Event::CellHover` (row, col, value).
      #
      # ```
      # hm = Widget::Graph::HeatMap.new parent: s, width: 30, height: 14,
      #   data: [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], colormap: :viridis
      # hm.on(Crysterm::Event::CellHover) { |e| puts "#{e.row},#{e.col} = #{e.value}" }
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![HeatMap screenshot](../../../tests/widget/graph/heatmap/heatmap.5s.apng)
      # <!-- /widget-examples:capture -->
      class HeatMap < Box
        include TextOverlay
        include InteriorCoords

        # One colormap stop: a normalized position `stop` (`0.0..1.0`) and its
        # color `rgb` (`0xRRGGBB`). Colors between stops are linearly
        # interpolated in RGB (via `Colors.mix`, as `Widget::Gradient` does).
        record ColorStop, stop : Float64, rgb : Int32

        # Named colormaps as ordered stops (first at `0.0`, last at `1.0`).
        # `:grayscale` and the perceptual `:viridis`/`:magma` are sequential;
        # `:coolwarm` is diverging (blue→white→red), best paired with
        # `#symmetric`.
        COLORMAPS = {
          :grayscale => [
            ColorStop.new(0.0, 0x000000), ColorStop.new(1.0, 0xFFFFFF),
          ],
          :viridis => [
            ColorStop.new(0.0, 0x440154), ColorStop.new(0.25, 0x3B528B),
            ColorStop.new(0.5, 0x21908C), ColorStop.new(0.75, 0x5DC863),
            ColorStop.new(1.0, 0xFDE725),
          ],
          :magma => [
            ColorStop.new(0.0, 0x000004), ColorStop.new(0.25, 0x3B0F70),
            ColorStop.new(0.5, 0x8C2981), ColorStop.new(0.75, 0xDE4968),
            ColorStop.new(1.0, 0xFCFDBF),
          ],
          :coolwarm => [
            ColorStop.new(0.0, 0x3B4CC0), ColorStop.new(0.5, 0xF7F7F7),
            ColorStop.new(1.0, 0xB40426),
          ],
        }

        # Row-major matrix of values. A `NaN` cell renders transparent (missing).
        # Stored as `@matrix` (`Widget` already owns an unrelated `@data`).
        @matrix : Array(Array(Float64))

        def data : Array(Array(Float64))
          @matrix
        end

        # Labels stamped across the top (`col_labels`) and down the left
        # (`row_labels`). Empty by default; truncated to fit their region.
        getter col_labels : Array(String)
        getter row_labels : Array(String)

        # Explicit color-scale bounds. `nil` (the default) auto-computes each
        # from the finite data.
        getter vmin : Float64?
        getter vmax : Float64?

        # Whether to center a diverging map at `0`: the resolved bounds become
        # `±max(|lo|, |hi|)`, so `0` lands on the colormap's midpoint.
        getter? symmetric : Bool

        # The active colormap (a key of `COLORMAPS`).
        getter colormap : Symbol

        # Whether to draw the colorbar legend down the right edge.
        property? show_legend : Bool

        # Whether to stamp the row/column axis labels.
        property? show_labels : Bool

        # The drawing surface, built in `#initialize`. `canvas` raises if read
        # before construction completes; `canvas?` is the nilable variant.
        getter! canvas : Canvas

        # 256-entry color LUT for the current `#colormap` (`t*255 -> 0xRRGGBB`),
        # built lazily and reused across repaints so the paint loop never does
        # per-cell float interpolation. Rebuilt only when `#colormap` changes.
        @lut : Array(Int32)?

        # Resolved `{vmin, vmax}` for the current data/bounds/`#symmetric`, cached
        # so repeated `#color_for` calls don't re-scan the matrix. Invalidated
        # when the data or any bound-affecting property changes.
        @bounds : Tuple(Float64, Float64)?

        # The last hovered cell, so `Event::CellHover` fires only on a change.
        @hover_cell : Tuple(Int32, Int32)?

        def initialize(
          data : Array(Array(Float64)) = [] of Array(Float64),
          vmin : Float64? = nil,
          vmax : Float64? = nil,
          colormap : Symbol = :viridis,
          col_labels : Array(String) = [] of String,
          row_labels : Array(String) = [] of String,
          @symmetric : Bool = false,
          @show_legend : Bool = true,
          @show_labels : Bool = true,
          type : Media::Type? = nil,
          glyph_mode : Media::Glyph::Mode = Media::Glyph::Mode::Block,
          **box,
        )
          @matrix = data.dup
          @col_labels = col_labels.dup
          @row_labels = row_labels.dup
          @vmin = vmin
          @vmax = vmax
          @colormap = colormap
          super **box

          cv = Canvas.new parent: self, type: type, glyph_mode: glyph_mode,
            top: 0, left: 0, right: 0, bottom: 0
          cv.on_paint { |p| paint_grid p }
          @canvas = cv

          # Map hovering onto the grid and re-emit as `Event::CellHover`. Hover
          # events fire on the topmost widget under the pointer; subscribing here
          # makes this widget mouse-hit-testable (`#wants_mouse?`).
          on(Crysterm::Event::MouseOver) { |e| handle_hover e }
          on(Crysterm::Event::MouseMove) { |e| handle_hover e }
          on(Crysterm::Event::MouseOut) { @hover_cell = nil }
        end

        # Replaces the whole matrix. Repaints and re-resolves the auto bounds.
        def data=(data : Array(Array(Float64))) : Array(Array(Float64))
          @matrix = data.dup
          @bounds = nil
          invalidate
          @matrix
        end

        def col_labels=(labels : Array(String)) : Array(String)
          @col_labels = labels.dup
          invalidate
          @col_labels
        end

        def row_labels=(labels : Array(String)) : Array(String)
          @row_labels = labels.dup
          invalidate
          @row_labels
        end

        # Sets the lower scale bound (`nil` re-enables auto). Rebuilds the
        # resolved bounds and repaints.
        def vmin=(v : Float64?) : Float64?
          @vmin = v
          @bounds = nil
          invalidate
          @vmin
        end

        def vmax=(v : Float64?) : Float64?
          @vmax = v
          @bounds = nil
          invalidate
          @vmax
        end

        def symmetric=(v : Bool) : Bool
          @symmetric = v
          @bounds = nil
          invalidate
          @symmetric
        end

        # Switches the colormap (a `COLORMAPS` key). Drops the LUT so the next
        # paint rebuilds it, then repaints.
        def colormap=(name : Symbol) : Symbol
          @colormap = name
          @lut = nil
          invalidate
          @colormap
        end

        def render(with_children = true)
          super
          draw_labels
          draw_legend
        end

        # The resolved `{vmin, vmax}` color-scale bounds for the current data —
        # explicit `#vmin`/`#vmax` where set, else the finite-data range, with
        # `#symmetric` centering and a `vmax == vmin` guard applied.
        def value_range : Tuple(Float64, Float64)
          resolved_bounds
        end

        # The `0xRRGGBB` color for value *v* under the current colormap and
        # resolved bounds: normalize to `t`, then index the precomputed LUT (no
        # per-cell interpolation on the paint path).
        def color_for(v : Float64) : Int32
          lo, hi = resolved_bounds
          t = ((v - lo) / (hi - lo)).clamp(0.0, 1.0)
          lut[(t * 255).round.to_i]
        end

        # Marks the Canvas content stale and schedules a render, so a data or
        # decoration change repaints (the Canvas skips otherwise, under its own
        # `@paint_dirty`). Mirrors `PieChart#invalidate`.
        private def invalidate : Nil
          canvas?.try &.invalidate_paint
          request_render
        end

        # The (lazily built) LUT for the active colormap.
        private def lut : Array(Int32)
          @lut ||= build_lut
        end

        # Precomputes a 256-entry `t*255 -> color` table by sampling the colormap
        # stops at `t = i/255`. `t = 0`/`1` land exactly on the first/last stop's
        # color, so `#color_for(vmin)`/`#color_for(vmax)` reproduce the endpoints.
        private def build_lut : Array(Int32)
          stops = COLORMAPS[@colormap]? || COLORMAPS[:grayscale]
          Array(Int32).new(256) { |i| sample_stops stops, i / 255.0 }
        end

        # Interpolates the colormap *stops* at normalized position *t* by linear
        # RGB lerp between the bracketing stops (reusing `Colors.mix`, exactly as
        # `Widget::Gradient#color_at` blends its stops). Only runs 256×/LUT build.
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

        # Resolves (and caches) the `{vmin, vmax}` bounds. `nil` bounds fall back
        # to the finite-data range; `#symmetric` recenters on `0`; a degenerate
        # `vmax <= vmin` (all-equal or single value) is widened by `1` so
        # normalization stays finite.
        private def resolved_bounds : Tuple(Float64, Float64)
          if b = @bounds
            return b
          end
          lo = @vmin
          hi = @vmax
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

        # Design's finalized grid pass: map the logical `cols × rows` space onto
        # the whole canvas and fill each finite cell with its color. Ragged rows
        # are tolerated (cells past a row's length are skipped); `NaN` cells are
        # left transparent.
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
          text_attr = sattr(style, style.fg, style.bg)

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

        # Stamps the colorbar down the right edge: one cell per row from `vmax`
        # (top) to `vmin` (bottom) in the colormap's colors, with numeric end
        # labels to its left. Uses colored cells (via `TextOverlay`) rather than
        # a second paint pass, mirroring how `PieChart` stamps its legend.
        private def draw_legend : Nil
          return unless show_legend?
          xi, xl, yi, yl = interior_coords || return
          return if xl - xi <= 2 || yl - yi <= 1

          lo, hi = resolved_bounds
          bar_x = xl - 1
          span = (yl - 1 - yi).to_f
          (yi...yl).each do |y|
            # Top row is `t = 1` (vmax), bottom is `t = 0` (vmin).
            t = span <= 0 ? 1.0 : 1.0 - (y - yi) / span
            put_cell bar_x, y, Scale::FULL, overlay_attr(lut[(t * 255).round.to_i]), xi, xl
          end

          # Numeric end labels, right-aligned just left of the bar.
          text_attr = sattr(style, style.fg, style.bg)
          hi_s = Scale.fmt hi
          lo_s = Scale.fmt lo
          put_text Math.max(xi, bar_x - hi_s.size), yi, hi_s, text_attr, xi, bar_x
          put_text Math.max(xi, bar_x - lo_s.size), yl - 1, lo_s, text_attr, xi, bar_x
        end

        # Emits `Event::CellHover` for the grid cell under the pointer, but only
        # when it differs from the last-hovered cell (avoids event spam on
        # motion). Reuses the pooled `Event::Mouse`'s absolute `x`/`y` and the
        # `interior_coords` mapping.
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
        # `nil` when outside the interior or the data is empty. Inverse of the
        # `paint_grid` mapping (the grid fills the whole interior).
        private def cell_at(x : Int32, y : Int32) : Tuple(Int32, Int32)?
          d = @matrix
          rows = d.size
          return nil if rows == 0
          cols = d[0].size
          return nil if cols == 0
          xi, xl, yi, yl = interior_coords || return nil
          return nil if xl <= xi || yl <= yi
          return nil if x < xi || x >= xl || y < yi || y >= yl
          col = ((x - xi) * cols) // (xl - xi)
          row = ((y - yi) * rows) // (yl - yi)
          {row.clamp(0, rows - 1), col.clamp(0, cols - 1)}
        end
      end
    end
  end
end
