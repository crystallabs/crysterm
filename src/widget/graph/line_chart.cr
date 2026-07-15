require "../box"
require "./canvas"
require "../../widget_graph_painter"
require "../../widget_graph_scale"

module Crysterm
  class Widget
    module Graph
      # An X/Y chart, modeled after Qt Charts' `QChart`. The plot is drawn on a
      # `Graph::Canvas` (best graphics backend available — sixel/kitty, else
      # braille), while the chrome — title, axes with ticks/labels, legend — is
      # real terminal text around it. This "plot = pixels, labels = text" split
      # keeps axis text crisp and selectable on every backend.
      #
      # The pieces:
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
      # ![LineChart screenshot](../../../tests/widget/graph/line_chart/line_chart.5s.apng)
      # <!-- /widget-examples:capture -->
      class LineChart < Box
        include TextOverlay
        include InteriorCoords

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

        # A named data series. `Kind` chooses how its points are drawn.
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

        # Toggling the grid changes what `#paint_plot` draws, so the setter must
        # invalidate the Canvas raster — which otherwise skips its repaint — and
        # schedule a render, or a stale grid stays on screen.
        def show_grid=(v : Bool) : Bool
          return v if v == @show_grid
          @show_grid = v
          plot?.try &.invalidate_paint
          request_render
          v
        end

        # The Canvas the plot is drawn on. Nilable only until `#initialize` has
        # run `super`; never `nil` post-construction.
        getter! plot : Canvas

        # Resolved data ranges for the current frame.
        @xmin = 0.0
        @xmax = 1.0
        @ymin = 0.0
        @ymax = 1.0

        @device : Media::Type?

        # Tick positions for the current frame, computed once per render (right
        # after `#compute_ranges`) and reused by the plot/margins/chrome. Refilled
        # in place by `#axis_values` only when the resolved range / tick params
        # change (see `#refresh_ticks`).
        @x_ticks = [] of Float64
        @y_ticks = [] of Float64

        # Formatted tick-label strings, parallel to `@x_ticks`/`@y_ticks`. Rebuilt
        # in place alongside the ticks so `#margins` and `#draw_chrome` reuse them
        # instead of re-`format`ting (and re-allocating `Array(String)`s) per frame.
        @x_labels = [] of String
        @y_labels = [] of String

        # Legend entry strings (`" name  "` per series), rebuilt only when the
        # series set changes rather than interpolated every frame in `#draw_chrome`.
        @legend_labels = [] of String

        # Bumped whenever the plotted data changes (series added / cleared /
        # mutated-then-`#refresh`ed) — i.e. everywhere `plot.invalidate_paint` is
        # called. Keys the tick/label and legend caches.
        @data_version = 0

        # Cache-validity stamps for the derived tick/label arrays and the legend.
        @ticks_key : Tuple(Float64, Float64, Float64, Float64, Int32, String, String, Int32, String, String)?
        @legend_version : Int32?

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
          # The plot Canvas draws the series, so its content is now stale.
          @data_version &+= 1
          plot?.try &.invalidate_paint
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
          @data_version &+= 1
          plot?.try &.invalidate_paint
          request_render
        end

        # Re-renders (e.g. after mutating a series' `points` in place).
        def refresh : Nil
          # Series points may have been mutated in place, so the plot is stale.
          @data_version &+= 1
          plot?.try &.invalidate_paint
          request_render
        end

        def render(with_children = true)
          compute_ranges
          # Tick positions + label strings are stable for the whole frame and only
          # change when the resolved range / tick params / series set change;
          # refill the reused ivars in place (no per-frame arrays) for #margins,
          # #paint_plot and #draw_chrome.
          refresh_ticks
          refresh_legend
          lm, tm, rm, bm = margins
          # Position the plot Canvas inside the chrome margins (no width/height
          # -> auto-stretch to the remaining interior).
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
              # A NaN/Infinity sample must not poison the auto-range: a NaN
              # min/max propagates into the tick fractions in `#draw_chrome`,
              # where `.round.to_i` raises OverflowError in the render fiber.
              next unless x.finite? && y.finite?
              xs_min = xs_min.nil? ? x : Math.min(xs_min, x)
              xs_max = xs_max.nil? ? x : Math.max(xs_max, x)
              ys_min = ys_min.nil? ? y : Math.min(ys_min, y)
              ys_max = ys_max.nil? ? y : Math.max(ys_max, y)
            end
          end
          @xmin = axis_x.minimum || xs_min || 0.0
          @xmax = axis_x.maximum || xs_max || 1.0
          @ymin = axis_y.minimum || ys_min || 0.0
          @ymax = axis_y.maximum || ys_max || 1.0
          # An explicit non-finite axis bound is as poisonous as a non-finite
          # sample — fall back to a sane default range.
          @xmin = 0.0 unless @xmin.finite?
          @xmax = 1.0 unless @xmax.finite?
          @ymin = 0.0 unless @ymin.finite?
          @ymax = 1.0 unless @ymax.finite?
          # Guard against zero spans (single point / flat data).
          @xmax = @xmin + 1.0 if @xmax <= @xmin
          @ymax = @ymin + 1.0 if @ymax <= @ymin
        end

        # Refills `@x_ticks`/`@y_ticks` and their parallel label strings in place,
        # but only when the resolved ranges, tick counts, or axis titles change —
        # so a steady chart does no per-frame `Array(Float64)`/`Array(String)`
        # allocation for its ticks or labels.
        private def refresh_ticks : Nil
          # `label_format` is in the key so a format change re-`format`s the
          # labels; `title` affects `#margins` via `lm` and keys along for free.
          key = {@xmin, @xmax, @ymin, @ymax,
                 axis_x.tick_count, axis_x.title, axis_x.label_format,
                 axis_y.tick_count, axis_y.title, axis_y.label_format}
          return if @ticks_key == key
          @ticks_key = key
          fill_axis @x_ticks, @x_labels, axis_x, @xmin, @xmax
          fill_axis @y_ticks, @y_labels, axis_y, @ymin, @ymax
        end

        private def fill_axis(ticks : Array(Float64), labels : Array(String),
                              axis : Axis, mn : Float64, mx : Float64) : Nil
          n = Math.max(2, axis.tick_count)
          ticks.clear
          labels.clear
          n.times do |i|
            v = mn + (mx - mn) * i / (n - 1)
            ticks << v
            labels << axis.format(v)
          end
        end

        # Rebuilds the legend entry strings only when the series set changes.
        private def refresh_legend : Nil
          return if @legend_version == @data_version
          @legend_version = @data_version
          @legend_labels.clear
          @series.each { |s| @legend_labels << " #{s.name}  " }
        end

        # --- plot (drawn on the Canvas) ---------------------------------------

        private def paint_plot(p : Painter) : Nil
          # Logical window with Y flipped (data up = window up): height is negative.
          p.set_window @xmin, @ymax, @xmax - @xmin, @ymin - @ymax

          if show_grid?
            p.pen = GRID_COLOR
            @x_ticks.each { |xv| p.draw_line xv, @ymin, xv, @ymax }
            @y_ticks.each { |yv| p.draw_line @xmin, yv, @xmax, yv }
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
              base = @ymin
              s.points.each { |(x, y)| p.draw_line x, base, x, y }
              p.draw_polyline s.points
            end
          end
        end

        # --- chrome (terminal text around the plot) ---------------------------

        # Left margin = widest Y label; top = title + legend rows; bottom = 1 (X
        # labels); right = enough for the last X label's overhang.
        private def margins : Tuple(Int32, Int32, Int32, Int32)
          lm = @y_labels.max_of?(&.size) || 0
          lm += 1 if axis_y.title.empty? # a hair of breathing room
          lm = lm.clamp(0, Math.max(0, (awidth - ihorizontal) // 2))

          tm = (@title.empty? ? 0 : 1) + (show_legend? && !@series.empty? ? 1 : 0)

          rm = ((@x_labels.last?.try(&.size) || 0) // 2).clamp(1, 4)

          {lm, tm, rm, 1}
        end

        private def draw_chrome(lm : Int32, tm : Int32, rm : Int32, bm : Int32) : Nil
          cl, cr, ct, cb = interior_coords || return
          return if cr - cl <= lm + rm || cb - ct <= tm + bm

          plot_l = cl + lm
          plot_r = cr - rm
          plot_t = ct + tm
          plot_b = cb - bm
          plot_w = plot_r - plot_l
          plot_h = plot_b - plot_t

          # Title (top row, centered over the content area).
          put_centered @title, cl, cr, ct, overlay_attr(LABEL_COLOR)

          # Legend (row under the title), each entry "■ name" in its color.
          if show_legend? && !@series.empty?
            ly = ct + (@title.empty? ? 0 : 1)
            x = cl
            @series.each_with_index do |s, i|
              break if x >= cr
              put_text x, ly, glyph(Glyphs::Role::LegendSwatch).to_s, overlay_attr(s.color), cl, cr
              label = @legend_labels[i]? || " #{s.name}  "
              put_text x + 1, ly, label, overlay_attr(LABEL_COLOR), cl, cr
              x += 1 + label.size
            end
          end

          # Y axis labels (right-aligned in the left margin, at each tick row).
          @y_ticks.each_with_index do |val, i|
            frac = (@ymax - val) / (@ymax - @ymin)
            next unless frac.finite? # belt-and-braces: NaN would raise on .to_i
            row = plot_t + (frac * (plot_h - 1)).round.to_i
            next if row < plot_t || row >= plot_b
            label = @y_labels[i]? || axis_y.format(val)
            put_text plot_l - label.size, row, label, overlay_attr(LABEL_COLOR), cl, plot_l
          end

          # X axis labels (centered under each tick column, on the bottom row).
          @x_ticks.each_with_index do |val, i|
            frac = (val - @xmin) / (@xmax - @xmin)
            next unless frac.finite? # belt-and-braces: NaN would raise on .to_i
            col = plot_l + (frac * (plot_w - 1)).round.to_i
            label = @x_labels[i]? || axis_x.format(val)
            x = col - label.size // 2
            put_text x, plot_b, label, overlay_attr(LABEL_COLOR), plot_l, cr
          end
        end
      end
    end
  end
end
