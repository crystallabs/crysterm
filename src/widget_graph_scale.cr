module Crysterm
  class Widget
    # Namespace for data-graphing widgets.
    module Graph
      # Shared helpers for the block-glyph graph widgets (`Bar`, `StackedBar`,
      # `Widget::Gauge`). Render numeric values with Unicode "eighth block"
      # glyphs, giving 8x sub-cell resolution along one axis.
      module Scale
        # Vertical eighth blocks: empty (0) .. full (8), filling *upward*.
        VERTICAL = " ▁▂▃▄▅▆▇█".chars

        # Horizontal eighth blocks: empty (0) .. full (8), filling *rightward*.
        HORIZONTAL = " ▏▎▍▌▋▊▉█".chars

        # Full cell — used where sub-cell resolution isn't needed (e.g. the
        # interior of a stacked segment).
        FULL = '█'

        # Number of filled eighth-cells (`0 .. cells*8`) representing `value` on
        # a `[min, max]` scale that spans `cells` whole character cells.
        def self.eighths(value : Float64, min : Float64, max : Float64, cells : Int32) : Int32
          range = max - min
          range = 1.0 if range <= 0.0
          norm = ((value - min) / range).clamp(0.0, 1.0)
          (norm * cells * 8).round.to_i
        end

        # Glyph for one *vertical* cell, given the column's total filled eighths
        # and how many whole cells sit below this one.
        def self.vglyph(filled_eighths : Int32, below_cells : Int32) : Char
          VERTICAL[(filled_eighths - below_cells * 8).clamp(0, 8)]
        end

        # Glyph for one *horizontal* cell, given the row's total filled eighths
        # and how many whole cells sit to the left of this one.
        def self.hglyph(filled_eighths : Int32, left_cells : Int32) : Char
          HORIZONTAL[(filled_eighths - left_cells * 8).clamp(0, 8)]
        end

        # Serializes a single row of `cells` into tagged content, wrapping each
        # run of same-colored cells in `{color-fg}…{/}`. A `nil` color emits the
        # characters as-is (default style). Coalescing runs keeps the produced
        # markup compact. Requires the target widget's `parse_tags?` to be on.
        def self.tagged_row(io : IO, cells : Array(Char), colors : Array(String?)) : Nil
          i = 0
          n = cells.size
          while i < n
            color = colors[i]
            j = i
            while j < n && colors[j] == color
              j += 1
            end
            io << "{#{color}-fg}" if color
            (i...j).each { |k| io << cells[k] }
            io << "{/}" if color
            i = j
          end
        end

        # Centers `text` within a field of `width` cells (truncating if longer),
        # padding with spaces. Used to place value/category labels under bars.
        def self.center(text : String, width : Int32) : String
          return "" if width <= 0
          return text[0, width] if text.size >= width
          pad = width - text.size
          left = pad // 2
          (" " * left) + text + (" " * (pad - left))
        end

        # Formats a numeric value compactly: integers lose their `.0`, others
        # are rounded to one decimal. Uses `to_i64` (not `to_i`, which is Int32
        # and raises `OverflowError` on ordinary large data — byte counts,
        # populations, timestamps ≥ 2³¹) when dropping the fractional part.
        def self.fmt(v : Float64) : String
          v == v.round ? v.to_i64.to_s : v.round(1).to_s
        end
      end

      # Interior-coordinate helper for Canvas-based graph widgets (`Donut`,
      # `Map`, `LineChart`) that draw text overlays inside their content area.
      # Mixed into `Box` subclasses.
      module InteriorCoords
        # The interior content rectangle `{xi, xl, yi, yl}` for the current frame,
        # inset by both padding *and* border (the base `with_inner_coords` insets
        # by border only), or `nil` when the widget isn't positioned yet
        # (`@lpos` unset). Callers early-return via `... || return`.
        private def interior_coords : Tuple(Int32, Int32, Int32, Int32)?
          lp = @lpos || return nil
          {lp.xi + ileft, lp.xl - iright, lp.yi + itop, lp.yl - ibottom}
        end
      end

      # Shared scaffolding for the block-glyph bar charts (`Bar`, `StackedBar`):
      # the bar-capacity arithmetic, the repaint-on-render hook, and the per-row
      # tagged-content builder. Including types are `Box` subclasses that declare
      # `@bar_width`/`@bar_spacing` (`Int32`) and a private `#build_content`.
      module BarChart
        # Bumped by `values=` and every decoration setter of the including chart,
        # so `#render` can tell when the plotted inputs changed. Together with the
        # interior size it keys the built-content cache below.
        @data_version = 0

        # The last built tagged-content string and the `{cols, rows, version}` key
        # it was built for. When nothing that affects the plot has changed since
        # the last frame, `#render` reuses the string instead of rebuilding it
        # (per-row char/string arrays, `String.build` per row, the final join).
        @content_cache : String?
        @content_cache_key : Tuple(Int32, Int32, Int32)?

        # Invalidate the built-content cache. Called from `values=` and each
        # decoration setter (see `Bar`/`StackedBar`).
        protected def bump_data_version : Nil
          @data_version &+= 1
        end

        # How many bars fit across `cols` columns at the current width/spacing.
        private def bar_capacity(cols : Int32) : Int32
          unit = @bar_width + @bar_spacing
          return 0 if unit <= 0 || cols <= 0
          # The last bar needs no trailing spacing, hence the `+ bar_spacing`.
          (cols + @bar_spacing) // unit
        end

        def render
          key = {awidth - iwidth, aheight - iheight, @data_version}
          content =
            if @content_cache_key == key && (cached = @content_cache)
              cached
            else
              @content_cache_key = key
              @content_cache = build_content
            end
          self.content = content
          super
        end

        # Builds one plot row of tagged content: each of the `n` bars contributes
        # `bar_width` copies of its `{glyph, color}` (yielded for bar `i`),
        # separated by `bar_spacing` blank columns. A blank glyph carries no color
        # so coalesced color runs stay tight.
        private def plot_row(n : Int32, & : Int32 -> {Char, String?}) : String
          # Pre-reserve the known final length so this per-frame rebuild doesn't
          # realloc its backing as it grows via `<<`.
          cap = n <= 0 ? 0 : n * @bar_width + (n - 1) * @bar_spacing
          cells = Array(Char).new(cap)
          colors = Array(String?).new(cap)
          n.times do |i|
            glyph, color = yield i
            @bar_width.times { cells << glyph; colors << (glyph == ' ' ? nil : color) }
            @bar_spacing.times { cells << ' '; colors << nil } if i < n - 1
          end
          String.build { |io| Scale.tagged_row(io, cells, colors) }
        end

        # Builds one caption row: each bar's text (yielded for bar `i`), centered
        # within its bar width, followed by the inter-bar spacing (plain,
        # untagged).
        private def field_line(n : Int32, &) : String
          String.build do |io|
            n.times do |i|
              io << Scale.center(yield(i), @bar_width)
              io << " " * @bar_spacing if i < n - 1
            end
          end
        end
      end
    end
  end
end
