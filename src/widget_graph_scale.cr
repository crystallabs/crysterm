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
          # A non-finite value (NaN from a `0/0` data point, or Infinity) survives
          # `clamp` — all NaN comparisons are false — and `NaN.round.to_i` raises
          # `OverflowError`, crashing the render. Render it as an empty column.
          return 0 unless value.finite?
          range = max - min
          range = 1.0 if range <= 0.0
          norm = ((value - min) / range).clamp(0.0, 1.0)
          # Defensive: a non-finite min/max can still yield a NaN `norm` above.
          norm = 0.0 if norm.nan?
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

        # `hglyph`/`vglyph` over an arbitrary fill *ramp* (empty → full steps — a
        # CSS `glyphs:` override or a registry sequence). The cell's fill (its
        # eighths, relative to `offset_cells` whole cells before it) maps onto the
        # ramp's steps: a 9-step ramp indexes 1:1 (the classic eighth blocks),
        # other lengths scale proportionally.
        def self.ramp_glyph(ramp : Array(Char), filled_eighths : Int32, offset_cells : Int32) : Char
          eighths = (filled_eighths - offset_cells * 8).clamp(0, 8)
          last = ramp.size - 1
          return ramp[0] if last <= 0
          ramp[(eighths * last / 8.0).round.to_i]
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
            if color
              io << '{' << color << "-fg}"
            end
            (i...j).each { |k| io << cells[k] }
            io << "{/}" if color
            i = j
          end
        end

        # Centers `text` within a field of `width` cells (truncating if longer),
        # padding with spaces. Returns a new `String`; prefer `#center_to` on the
        # render path.
        def self.center(text : String, width : Int32, full_unicode : Bool = false) : String
          String.build { |io| center_to io, text, width, full_unicode }
        end

        # Writes `text`, centered within a field of `width` cells (truncating if
        # longer), straight to *io* — pads are emitted char-by-char rather than
        # via `" " * n` + concatenation, so a per-frame caption row builds with
        # no intermediate `String`s.
        #
        # When *full_unicode* is true the field is measured and truncated in
        # terminal DISPLAY columns (wide CJK/emoji graphemes count as 2, and
        # graphemes are never split), matching how the plot rows are laid out.
        # Otherwise codepoint sizing (`text.size` / `text[0, width]`) applies.
        def self.center_to(io : IO, text : String, width : Int32, full_unicode : Bool = false) : Nil
          return if width <= 0
          tw = full_unicode ? Unicode.display_width(text) : text.size
          if tw >= width
            if full_unicode
              # Keep the leading `width` columns: drop trailing graphemes once
              # the next one would overflow (never split a grapheme).
              io << text.byte_slice(0, Unicode.leading_byte_len(text, width, true))
            else
              io << text[0, width]
            end
            return
          end
          pad = width - tw
          left = pad // 2
          left.times { io << ' ' }
          io << text
          (pad - left).times { io << ' ' }
        end

        # Formats a numeric value compactly: integers lose their `.0`, others
        # are rounded to one decimal. Uses `to_i64` (not `to_i`, which is Int32
        # and raises `OverflowError` on ordinary large data — byte counts,
        # populations, timestamps ≥ 2³¹) when dropping the fractional part.
        def self.fmt(v : Float64) : String
          # A non-finite value (Infinity from a divide-by-zero / `log(0)` in the
          # plotted data, or NaN) has `v == v.round`, so the whole-number branch
          # would call `Infinity.to_i64` — an `OverflowError` that crashes the
          # render. A *finite* whole value beyond Int64 (≥ ~9.22e18) overflows it
          # just the same. Render both as their plain string.
          return v.to_s unless v.finite? && v.abs < 9.2e18
          v == v.round ? v.to_i64.to_s : v.round(1).to_s
        end
      end

      # Interior-coordinate helper for Canvas-based graph widgets (`Donut`,
      # `Map`, `LineChart`) that draw text overlays inside their content area.
      # Mixed into `Box` subclasses.
      module InteriorCoords
        # The interior content rectangle `{xi, xl, yi, yl}` for the current frame,
        # inset by both padding *and* border (the base `with_inner_coords` insets
        # by border only), or `nil` when the widget isn't positioned yet.
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
        # it was built for. When nothing affecting the plot changed since the last
        # frame, `#render` reuses the string instead of rebuilding it.
        @content_cache : String?
        @content_cache_key : Tuple(Int32, Int32, Int32)?

        # Invalidate the built-content cache.
        protected def bump_data_version : Nil
          @data_version &+= 1
        end

        # A getter plus a setter that also bumps the content-cache version, so a
        # decoration change invalidates the per-frame build cache.
        macro chart_prop(name, type)
          getter {{name.id}} : {{type}}

          def {{name.id}}=(value : {{type}})
            @{{name.id}} = value
            bump_data_version
            value
          end
        end

        # How many bars fit across `cols` columns at the current width/spacing.
        private def bar_capacity(cols : Int32) : Int32
          unit = @bar_width + @bar_spacing
          return 0 if unit <= 0 || cols <= 0
          # The last bar needs no trailing spacing, hence the `+ bar_spacing`.
          (cols + @bar_spacing) // unit
        end

        def render
          key = {awidth - ihorizontal, aheight - ivertical, @data_version}
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

        # Writes one plot row of tagged content into *io*: each of the `n` bars
        # contributes `bar_width` copies of its `{glyph, color}` (yielded for bar
        # `i`), separated by `bar_spacing` blank columns. A blank glyph carries no
        # color so coalesced color runs stay tight.
        #
        # Streams straight into the caller's builder so `#build_content` composes
        # the whole widget in one `String.build`: no per-row scratch `String`, no
        # final `Array#join`, and none of the scratch `Array`s `Scale.tagged_row`
        # materializes. Output is byte-identical to `tagged_row`'s.
        private def plot_row(io : IO, n : Int32, & : Int32 -> {Char, String?}) : Nil
          open_color : String? = nil
          n.times do |i|
            glyph, color = yield i
            cell_color = glyph == ' ' ? nil : color
            @bar_width.times do
              if cell_color != open_color
                io << "{/}" if open_color
                if c = cell_color
                  io << '{' << c << "-fg}"
                end
                open_color = cell_color
              end
              io << glyph
            end
            if i < n - 1
              @bar_spacing.times do
                if open_color
                  io << "{/}"
                  open_color = nil
                end
                io << ' '
              end
            end
          end
          io << "{/}" if open_color
        end

        # Writes one caption row into *io*: each bar's text (yielded for bar `i`),
        # centered within its bar width, followed by the inter-bar spacing (plain,
        # untagged).
        private def field_line(io : IO, n : Int32, &) : Nil
          n.times do |i|
            Scale.center_to(io, yield(i), @bar_width, full_unicode?)
            @bar_spacing.times { io << ' ' } if i < n - 1
          end
        end
      end
    end
  end
end
