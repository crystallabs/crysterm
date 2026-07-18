require "../box"
require "../../widget_graph_scale"

module Crysterm
  class Widget
    module Graph
      # A stacked vertical bar chart: every bar is a pile of colored segments,
      # in the spirit of Qt's `QStackedBarSeries`.
      #
      # `#values` is an array of bars, and each bar is itself an array of segment
      # values (one per *stack level*). Segments are drawn bottom-up, each in its
      # color from `#colors` (cycled by stack level). A bar's total height is its
      # segment sum scaled against `#max` (or the largest bar's sum when `#max`
      # is `nil`).
      #
      # `#segment_labels` names the stack levels; with `#show_legend?` on, a
      # one-row color key is drawn along the top. `#labels` captions each bar
      # along the bottom. As with `Bar`, when more bars are supplied than fit,
      # the tail is shown.
      #
      # ```
      # sb = Widget::Graph::StackedBar.new parent: s, width: 50, height: 12,
      #   bar_width: 5, bar_spacing: 3, max: 100.0,
      #   colors: %w[green yellow red],
      #   segment_labels: %w[idle warn crit],
      #   labels: %w[web db cache]
      # sb.values = [[60, 30, 10], [20, 50, 30], [80, 15, 5]]
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![StackedBar screenshot](../../../tests/widget/graph/stacked_bar/stacked_bar.5s.apng)
      # <!-- /widget-examples:capture -->
      class StackedBar < Box
        include BarChart

        # Default segment palette, cycled by stack level.
        DEFAULT_COLORS = %w[green magenta cyan red blue yellow]

        # The data series. Each element is one bar: an array of segment values,
        # bottom-most first. The coercing `#values=` is the sole setter, so every
        # assignment bumps the content-cache version.
        getter values : Array(Array(Float64))

        # Category captions drawn (centered, one row) under each bar.
        chart_prop labels, Array(String)?

        # Names of the stack levels, shown in the legend.
        chart_prop segment_labels, Array(String)?

        # Per-stack-level foreground colors, cycled by level.
        chart_prop colors, Array(String)

        # Top of the scale (a bar's full height equals its summed value reaching
        # this). `nil` auto-scales to the largest bar's sum each frame.
        chart_prop max, Float64?

        # Width of each bar, in columns.
        chart_prop bar_width, Int32

        # Empty columns between adjacent bars.
        chart_prop bar_spacing, Int32

        # Whether to draw the color-key legend (needs `#segment_labels`).
        getter? show_legend : Bool

        def show_legend=(value : Bool)
          @show_legend = value
          bump_data_version
          # Rebuilds the content and schedules a frame (mirrors `values=`).
          mark_dirty
          value
        end

        def initialize(
          values : Array = [] of Array(Float64),
          @labels : Array(String)? = nil,
          @segment_labels : Array(String)? = nil,
          @colors : Array(String) = DEFAULT_COLORS,
          @max : Float64? = nil,
          @bar_width : Int32 = 3,
          @bar_spacing : Int32 = 2,
          @show_legend : Bool = true,
          **box,
        )
          @values = values.map { |bar| bar.map(&.to_f) }
          super **box
          self.parse_tags = true
        end

        # Accepts any array-of-numeric-arrays, coercing to `Float64`.
        def values=(vals : Array)
          @values = vals.map { |bar| bar.map(&.to_f) }
          bump_data_version
          mark_dirty
        end

        private def segment_color(level : Int32) : String
          # An empty `colors` falls back to the default palette: segments are
          # color-keyed so there is no "no color" here, and `level % 0` would
          # raise `DivisionByZeroError`.
          colors = @colors.empty? ? DEFAULT_COLORS : @colors
          colors[level % colors.size]
        end

        private def build_content : String
          cols = awidth - ihorizontal
          rows = aheight - ivertical
          return "" if cols <= 0 || rows <= 0 || @values.empty?

          seg_lbls = @segment_labels
          legend_row = (show_legend? && seg_lbls && !seg_lbls.empty?) ? 1 : 0
          lbls = @labels
          label_row = (lbls && !lbls.empty?) ? 1 : 0
          plot_rows = rows - legend_row - label_row
          return "" if plot_rows <= 0

          cap = bar_capacity(cols)
          return "" if cap <= 0
          shown = @values.last(cap)
          n = shown.size

          sums = shown.map(&.sum)
          top = @max || (sums.select(&.finite?).max? || 0.0)
          top = 1.0 if top <= 0.0

          # Fill ramp: CSS-first (`glyphs:`), then the registry. Resolved once
          # here rather than per bar.
          ramp = glyph_seq(Glyphs::SeqRole::ScaleVertical, style, cells: true)

          # For each shown bar, the per-row (glyph, color) from top to bottom.
          columns = shown.map { |bar| column(bar, plot_rows, top, ramp) }

          # One builder for the whole widget, rows separated by `\n`. A per-row
          # `String` array plus a final join would be pure per-frame garbage: a
          # live chart rebuilds this on every data push.
          String.build do |io|
            wrote = false

            # Legend along the top.
            if legend_row == 1
              legend_line(io, seg_lbls.not_nil!, cols) # ameba:disable Lint/NotNil
              wrote = true
            end

            # Plot area.
            plot_rows.times do |r|
              io << '\n' if wrote
              wrote = true
              plot_row(io, n) { |i| columns[i][r] }
            end

            # Category captions along the bottom, offset to match the tail bars
            # shown when values overflow the width (`@values.last(cap)`).
            if label_row == 1
              io << '\n' if wrote
              names = lbls.not_nil! # ameba:disable Lint/NotNil
              offset = @values.size - n
              field_line(io, n) { |i| names[offset + i]? || "" }
            end
          end
        end

        # Computes the per-row `{glyph, color}` for one bar (index 0 = top row).
        #
        # The bar's *total* height is measured in eighth-cells, so the top of the
        # stack lands on a sub-cell block glyph (`▁`..`█`). Segment boundaries
        # *within* the stack snap to whole cells, since a single cell can't show
        # two colors; only the topmost segment keeps the sub-cell partial.
        private def column(bar : Array(Float64), plot_rows : Int32, top : Float64, ramp : Array(Char)) : Array({Char, String?})
          blank = {' ', nil.as(String?)}
          col = Array({Char, String?}).new(plot_rows, blank)
          sum = bar.sum
          return col if sum <= 0

          # Total filled height of the whole bar, in eighth-cells from the bottom.
          total = Scale.eighths(sum, 0.0, top, plot_rows)
          return col if total <= 0

          # Per-segment top edge (eighths from the bottom). Internal edges snap to
          # a whole cell; the topmost segment's edge is the exact total.
          last = bar.size - 1
          tops = Array(Int32).new(bar.size, 0)
          cum = 0.0
          prev = 0
          bar.each_with_index do |seg, level|
            cum += seg
            edge = (total * (cum / sum)).round.to_i
            edge = ((edge + 4) // 8) * 8 if level < last # snap to nearest cell
            edge = total if level == last                # topmost: sub-cell exact
            edge = edge.clamp(prev, total)
            tops[level] = edge
            prev = edge
          end

          plot_rows.times do |r|
            below = plot_rows - 1 - r # whole cells beneath this one
            glyph = Scale.ramp_glyph(ramp, total, below)
            next if glyph == ' ' # cell above the fill
            edge = below * 8     # this cell's bottom edge, in eighths
            color = nil.as(String?)
            bottom = 0
            bar.size.times do |level|
              if edge >= bottom && edge < tops[level]
                color = segment_color(level)
                break
              end
              bottom = tops[level]
            end
            col[r] = {glyph, color}
          end
          col
        end

        # Writes the one-row legend into *io*: `█ name` swatches, color-coded by
        # level.
        private def legend_line(io : IO, names : Array(String), cols : Int32) : Nil
          width = 0
          names.each_with_index do |name, level|
            entry = "#{Scale::FULL} #{name}"
            # The separating space must be in the overflow check too, or a
            # too-wide entry overruns the legend by that separator.
            sep = level > 0 ? 1 : 0
            break if width + sep + entry.size > cols
            io << ' ' if level > 0
            io << "{#{segment_color(level)}-fg}#{Scale::FULL}{/} #{name}"
            width += entry.size + sep
          end
        end
      end
    end
  end
end
