require "../box"
require "../../widget_graph_scale"

module Crysterm
  class Widget
    module Graph
      # A vertical bar chart drawn with Unicode eighth-block glyphs
      # (`▁▂▃▄▅▆▇█`), giving each bar ~8× the vertical resolution of whole
      # character cells. In the spirit of Qt's `QBarSeries`/`QBarSet`.
      #
      # Each value in `#values` becomes one bar, `#bar_width` columns wide and
      # separated by `#bar_spacing` empty columns, rising from the bottom in
      # proportion to its place in the `#min`..`#max` range. When there are more
      # values than fit, the most recent ones (the tail) are shown — so feeding
      # it a rolling window animates like a live chart. With `bar_width: 1`,
      # `bar_spacing: 0` and a height of 1 it degenerates into a one-row
      # *sparkline*.
      #
      # Optional decorations, all off by default so the bare widget stays a
      # compact plot:
      # - `#labels` — a category caption centered under each bar.
      # - `#show_values?` — the numeric value centered under each bar.
      # - `#colors` — per-bar foreground colors, cycled across the bars.
      #
      # ```
      # bar = Widget::Graph::Bar.new parent: s, width: 40, height: 8, max: 100.0,
      #   bar_width: 4, bar_spacing: 2, show_values: true,
      #   labels: %w[cpu mem net io], colors: %w[green cyan yellow red]
      # bar.values = [42, 88, 13, 64]
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![Bar screenshot](../../../tests/widget/graph/bar/bar.5s.apng)
      # <!-- /widget-examples:capture -->
      class Bar < Box
        include BarChart

        # The data series. Each element is one bar.
        getter values : Array(Float64)

        # Category captions drawn (centered, one row) under each bar. `nil` or
        # empty for none.
        chart_prop labels, Array(String)?

        # Bottom of the scale (the baseline a zero-height bar sits at).
        chart_prop min, Float64

        # Top of the scale. `nil` auto-scales to the largest shown value each
        # frame; set a fixed value for a stable axis (no jumping).
        chart_prop max, Float64?

        # Width of each bar, in columns.
        chart_prop bar_width, Int32

        # Empty columns between adjacent bars.
        chart_prop bar_spacing, Int32

        # Whether to draw each bar's numeric value (centered, one row) under it.
        getter? show_values : Bool

        def show_values=(value : Bool)
          @show_values = value
          bump_data_version
          value
        end

        # Per-bar foreground colors, cycled across bars. `nil` uses the widget's
        # own `style.fg`.
        chart_prop colors, Array(String)?

        def initialize(
          values : Array = [] of Float64,
          @labels : Array(String)? = nil,
          @min : Float64 = 0.0,
          @max : Float64? = nil,
          @bar_width : Int32 = 1,
          @bar_spacing : Int32 = 0,
          @show_values : Bool = false,
          @colors : Array(String)? = nil,
          **box,
        )
          @values = values.map(&.to_f)
          super **box
          # Bars/labels are emitted as tagged content (color runs).
          self.parse_tags = true
        end

        # Accepts any numeric array, coercing to `Float64`.
        def values=(vals : Array)
          @values = vals.map(&.to_f)
          bump_data_version
          mark_dirty
        end

        private def bar_color(i : Int32) : String?
          # An empty `colors` array means "no per-bar color" (use `style.fg`),
          # like `nil`; it also guards the modulo against `i % 0`.
          c = @colors
          (c && !c.empty?) ? c[i % c.size] : nil
        end

        # Builds the (tagged) glyph grid for the current size and values.
        private def build_content : String
          cols = awidth - ihorizontal
          rows = aheight - ivertical
          return "" if cols <= 0 || rows <= 0 || @values.empty?

          lbls = @labels
          label_row = (lbls && !lbls.empty?) ? 1 : 0
          value_row = show_values? ? 1 : 0
          plot_rows = rows - label_row - value_row
          return "" if plot_rows <= 0

          cap = bar_capacity(cols)
          return "" if cap <= 0
          shown = @values.last(cap)
          n = shown.size

          top = @max || (shown.select(&.finite?).max? || 0.0)
          # Total filled eighth-cells per shown bar.
          levels = shown.map { |v| Scale.eighths(v, @min, top, plot_rows) }

          # Plot area, top row down. The fill ramp resolves CSS-first
          # (`glyphs:`), then the registry's `ScaleVertical`. Composed straight
          # into one builder (rows separated by `\n`): a live chart rebuilds this
          # on every data push, so a per-row array + join would be pure garbage.
          ramp = glyph_seq(Glyphs::SeqRole::ScaleVertical, style, cells: true)
          String.build do |io|
            plot_rows.times do |r|
              io << '\n' if r > 0
              below = plot_rows - 1 - r
              plot_row(io, n) { |i| {Scale.ramp_glyph(ramp, levels[i], below), bar_color(i)} }
            end

            # Value captions.
            if value_row == 1
              io << '\n'
              field_line(io, n) { |i| Scale.fmt(shown[i]) }
            end

            # Category captions. When values overflow the width only the tail is
            # shown, so labels must follow the same offset or they mislabel the
            # visible bars.
            if label_row == 1
              io << '\n'
              names = lbls.not_nil! # ameba:disable Lint/NotNil
              offset = @values.size - n
              field_line(io, n) { |i| names[offset + i]? || "" }
            end
          end
        end
      end
    end
  end
end
