require "../box"
require "./canvas"
require "../../widget_graph_scale"

module Crysterm
  class Widget
    module Graph
      # An X/Y chart, modeled after Qt Charts' `QChart` rather than
      # blessed-contrib's `line`. The plot itself is drawn on a `Graph::Canvas`
      # (so it uses the best graphics backend the terminal supports — sixel/kitty,
      # else braille), while the *chrome* — title, value axes with ticks/labels,
      # and legend — is real terminal text laid out around it. This is the
      # "plot = pixels, labels = text" split, and it's why the axis text stays
      # crisp and selectable on every backend.
      #
      # Qt-style pieces:
      #
      # * `Series` — a named data series with a color and a `Kind`
      #   (`Line`/`Scatter`/`Area`), like `QLineSeries`/`QScatterSeries`/
      #   `QAreaSeries`. Add with `#add_line` / `#add_scatter` / `#add_area`.
      # * `Axis` (`#axis_x`, `#axis_y`) — a `QValueAxis`-like value axis with
      #   `#minimum`/`#maximum` (`nil` = auto-range from the data), `#tick_count`,
      #   `#title` and `#label_format`.
      # * `#title`, `#show_legend?`, `#show_grid?` — chart chrome toggles.
      #
      # ```
      # chart = Widget::Graph::LineChart.new parent: s, width: 60, height: 18,
      #   title: "Signals", style: Style.new(border: true)
      # chart.add_line "sin", (0..100).map { |i| {i / 10.0, Math.sin(i / 10.0)} }
      # chart.add_line "cos", (0..100).map { |i| {i / 10.0, Math.cos(i / 10.0)} }
      # chart.axis_y.minimum = -1.0
      # chart.axis_y.maximum = 1.0
      # chart.refresh
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![LineChart screenshot](../../../examples/widget/graph/line_chart/line_chart-capture5s.apng)
      # <!-- /widget-examples:capture -->
      class LineChart < Box
        # A `QValueAxis`-like value axis. `#minimum`/`#maximum` of `nil` auto-range
        # from the plotted data.
        class Axis
          property minimum : Float64?
          property maximum : Float64?
          property tick_count : Int32
          property title : String
          # `sprintf` format for tick labels (e.g. `"%.1f"`); empty picks a
          # compact default (`Scale.fmt`).
          property label_format : String

          def initialize(@minimum = nil, @maximum = nil, @tick_count = 5,
                         @title = "", @label_format = "")
          end

          def format(value : Float64) : String
            @label_format.empty? ? Scale.fmt(value) : (@label_format % value)
          end
        end

        # A named data series. `Kind` chooses how its points are drawn, mirroring
        # Qt's `QLineSeries` / `QScatterSeries` / `QAreaSeries`.
        class Series
          enum Kind
            Line
            Scatter
            Area
          end

          property name : String
          property points : Array(Tuple(Float64, Float64))
          property color : Int32
          property kind : Kind

          def initialize(@name, points : Array, @color : Int32, @kind : Kind = Kind::Line)
            @points = points.map { |pt| {pt[0].to_f, pt[1].to_f} }
          end
        end

        # Distinct default series colors (cycled), à la a chart theme.
        PALETTE = [0x40E0D0, 0xE0A040, 0x60C040, 0xD060C0, 0x4090E0, 0xE05050, 0xC0C040]

        # Grid + axis-label colors.
        GRID_COLOR  = 0x303840
        LABEL_COLOR = 0x90A0B0

        getter series : Array(Series) = [] of Series
        getter axis_x : Axis = Axis.new
        getter axis_y : Axis = Axis.new
        property title : String
        property? show_legend : Bool
        property? show_grid : Bool

        # The Canvas the plot is drawn on. Built in `#initialize` after `super`
        # (so it is stored nilable but is never `nil` post-construction).
        @plot : Canvas?

        # The plot's drawing surface.
        def plot : Canvas
          @plot.not_nil!
        end

        # Resolved data ranges for the current frame (set in `#compute_ranges`,
        # read by the plot's paint callback).
        @xmin = 0.0
        @xmax = 1.0
        @ymin = 0.0
        @ymax = 1.0

        @device : Media::Type?

        def initialize(
          @title : String = "",
          @show_legend : Bool = true,
          @show_grid : Bool = true,
          type : Media::Type? = nil,
          glyph_mode : Media::Glyph::Mode = Media::Glyph::Mode::Braille,
          **box,
        )
          super **box

          pl = Canvas.new parent: self, type: type, glyph_mode: glyph_mode
          pl.on_paint { |p| paint_plot p }
          @plot = pl
        end

        # Adds a series (Qt's `QChart#addSeries`). A `nil` color is auto-assigned
        # from `PALETTE` by series index.
        def add_series(name : String, points : Array, color : Int32? = nil,
                       kind : Series::Kind = Series::Kind::Line) : Series
          s = Series.new name, points, color || PALETTE[@series.size % PALETTE.size], kind
          @series << s
          request_render
          s
        end

        def add_line(name : String, points : Array, color : Int32? = nil) : Series
          add_series name, points, color, Series::Kind::Line
        end

        def add_scatter(name : String, points : Array, color : Int32? = nil) : Series
          add_series name, points, color, Series::Kind::Scatter
        end

        def add_area(name : String, points : Array, color : Int32? = nil) : Series
          add_series name, points, color, Series::Kind::Area
        end

        # Removes all series.
        def clear_series : Nil
          @series.clear
          request_render
        end

        # Re-renders (e.g. after mutating a series' `points` in place).
        def refresh : Nil
          request_render
        end

        def render(with_children = true)
          compute_ranges
          lm, tm, rm, bm = margins
          # Position the plot Canvas inside the chrome margins (no width/height ->
          # auto-stretch to the remaining interior).
          pl = plot
          pl.left = lm
          pl.top = tm
          pl.right = rm
          pl.bottom = bm
          super
          draw_chrome lm, tm, rm, bm
        end

        # --- ranges -----------------------------------------------------------

        private def compute_ranges : Nil
          xs_min = xs_max = ys_min = ys_max = nil
          @series.each do |s|
            s.points.each do |(x, y)|
              xs_min = x if xs_min.nil? || x < xs_min.not_nil!
              xs_max = x if xs_max.nil? || x > xs_max.not_nil!
              ys_min = y if ys_min.nil? || y < ys_min.not_nil!
              ys_max = y if ys_max.nil? || y > ys_max.not_nil!
            end
          end
          @xmin = axis_x.minimum || xs_min || 0.0
          @xmax = axis_x.maximum || xs_max || 1.0
          @ymin = axis_y.minimum || ys_min || 0.0
          @ymax = axis_y.maximum || ys_max || 1.0
          # Guard against zero spans (single point / flat data).
          @xmax = @xmin + 1.0 if @xmax <= @xmin
          @ymax = @ymin + 1.0 if @ymax <= @ymin
        end

        private def axis_values(axis : Axis, mn : Float64, mx : Float64) : Array(Float64)
          n = Math.max(2, axis.tick_count)
          Array.new(n) { |i| mn + (mx - mn) * i / (n - 1) }
        end

        # --- plot (drawn on the Canvas) ---------------------------------------

        private def paint_plot(p : Painter) : Nil
          # Logical window with Y flipped (data up ⇒ screen up): height is negative.
          p.set_window @xmin, @ymax, @xmax - @xmin, @ymin - @ymax

          if show_grid?
            p.pen = GRID_COLOR
            axis_values(axis_x, @xmin, @xmax).each { |xv| p.draw_line xv, @ymin, xv, @ymax }
            axis_values(axis_y, @ymin, @ymax).each { |yv| p.draw_line @xmin, yv, @xmax, yv }
          end

          @series.each do |s|
            p.pen = s.color
            case s.kind
            in Series::Kind::Line
              p.draw_polyline s.points
            in Series::Kind::Scatter
              s.points.each { |(x, y)| p.draw_marker x, y, 1 }
            in Series::Kind::Area
              # Vertical fill from each sample down to the baseline, plus the
              # outline on top (reads as a filled area for dense series).
              base = @ymin.clamp(@ymin, @ymax)
              s.points.each { |(x, y)| p.draw_line x, base, x, y }
              p.draw_polyline s.points
            end
          end
        end

        # --- chrome (terminal text around the plot) ---------------------------

        # Left margin = widest Y label; top = title + legend rows; bottom = 1 (X
        # labels); right = enough for the last X label's overhang.
        private def margins : Tuple(Int32, Int32, Int32, Int32)
          y_labels = axis_values(axis_y, @ymin, @ymax).map { |v| axis_y.format v }
          lm = y_labels.max_of?(&.size) || 0
          lm += 1 if axis_y.title.empty? # a hair of breathing room
          lm = lm.clamp(0, Math.max(0, (awidth - iwidth) // 2))

          tm = (@title.empty? ? 0 : 1) + (show_legend? && !@series.empty? ? 1 : 0)

          x_labels = axis_values(axis_x, @xmin, @xmax).map { |v| axis_x.format v }
          rm = ((x_labels.last?.try(&.size) || 0) // 2).clamp(1, 4)

          {lm, tm, rm, 1}
        end

        private def draw_chrome(lm : Int32, tm : Int32, rm : Int32, bm : Int32) : Nil
          lp = @lpos || return
          cl = lp.xi + ileft
          cr = lp.xl - iright
          ct = lp.yi + itop
          cb = lp.yl - ibottom
          return if cr - cl <= lm + rm || cb - ct <= tm + bm

          plot_l = cl + lm
          plot_r = cr - rm
          plot_t = ct + tm
          plot_b = cb - bm
          plot_w = plot_r - plot_l
          plot_h = plot_b - plot_t

          # Title (top row, centered over the content area).
          unless @title.empty?
            tx = cl + Math.max(0, (cr - cl - @title.size) // 2)
            put_text tx, ct, @title, text_attr(LABEL_COLOR), cl, cr
          end

          # Legend (row under the title), each entry "■ name" in its color.
          if show_legend? && !@series.empty?
            ly = ct + (@title.empty? ? 0 : 1)
            x = cl
            @series.each do |s|
              break if x >= cr
              put_text x, ly, "■", text_attr(s.color), cl, cr
              label = " #{s.name}  "
              put_text x + 1, ly, label, text_attr(LABEL_COLOR), cl, cr
              x += 1 + label.size
            end
          end

          # Y axis labels (right-aligned in the left margin, at each tick row).
          axis_values(axis_y, @ymin, @ymax).each do |val|
            frac = (@ymax - val) / (@ymax - @ymin)
            row = plot_t + (frac * (plot_h - 1)).round.to_i
            next if row < plot_t || row >= plot_b
            label = axis_y.format val
            put_text plot_l - label.size, row, label, text_attr(LABEL_COLOR), cl, plot_l
          end

          # X axis labels (centered under each tick column, on the bottom row).
          axis_values(axis_x, @xmin, @xmax).each do |val|
            frac = (val - @xmin) / (@xmax - @xmin)
            col = plot_l + (frac * (plot_w - 1)).round.to_i
            label = axis_x.format val
            x = col - label.size // 2
            put_text x, plot_b, label, text_attr(LABEL_COLOR), plot_l, cr
          end
        end

        # Caches an attr per color so labels don't rebuild a `Style` per cell.
        @attr_cache = {} of Int32 => Int64

        private def text_attr(color : Int32) : Int64
          @attr_cache[color] ||= sattr(style, color, style.bg)
        end

        # Writes *text* at absolute cell (x, y), clipped to the half-open column
        # range `[clip_lo, clip_hi)` so labels never bleed past their region.
        private def put_text(x : Int32, y : Int32, text : String, attr : Int64,
                             clip_lo : Int32, clip_hi : Int32) : Nil
          line = screen.lines[y]?
          return unless line
          text.each_char_with_index do |ch, i|
            cx = x + i
            next if cx < clip_lo || cx >= clip_hi
            if cell = line[cx]?
              cell.char = ch
              cell.attr = attr
            end
          end
          line.dirty = true
        end
      end
    end
  end
end
