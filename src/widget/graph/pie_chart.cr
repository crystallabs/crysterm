require "../box"
require "./canvas"
require "../../widget_graph_painter"
require "../../widget_graph_scale"

module Crysterm
  class Widget
    module Graph
      # A categorical pie chart: a circle divided into N proportional, colored
      # slices, in the spirit of Qt's `QPieSeries`. A radial sibling of
      # `Graph::Donut` (not a subclass): a Donut shows one `#value` in a range,
      # whereas a pie has no range — each `#slices` entry is a category whose
      # arc length is its share of the total.
      #
      # Each slice is drawn as a solid wedge on a backend-agnostic `Graph::Canvas`
      # (sixel/kitty where available, else braille); the wedge primitive is
      # `Painter#fill_ring` with `r_inner = 0`. Set `#inner_radius` above `0` to
      # punch a hole through the middle and render the categories as a multi-slice
      # ring instead. Slices sweep clockwise from 12 o'clock, in insertion order.
      #
      # With `#show_legend?` on (the default) a color key — swatch, label and (if
      # `#show_percentages?`) the slice's percentage — is stamped as terminal text
      # over the bottom of the chart.
      #
      # ```
      # pie = Widget::Graph::PieChart.new parent: s, width: 24, height: 12
      # pie.add_slice "web", 50, 0x40E0D0
      # pie.add_slice "db", 30, 0xE0A040
      # pie.add_slice "cache", 20, 0xE04060
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![PieChart screenshot](../../../tests/widget/graph/pie_chart/pie_chart.5s.apng)
      # <!-- /widget-examples:capture -->
      class PieChart < Box
        include TextOverlay
        include InteriorCoords
        include RingGeometry
        include Mixin::CanvasOwner

        # One categorical wedge: its `value` (share of the total), fill `color`
        # and legend `label`. The color is stored as a native `0xRRGGBB` `Int32`
        # but a color *name*/`"#rrggbb"` string is accepted and converted.
        struct Slice
          getter value : Float64
          getter color : Int32
          getter label : String

          def initialize(value : Number, color : Int32 | String, @label : String = "")
            @value = value.to_f
            @color = Colors.to_native color
          end
        end

        # Default slice palette (`0xRRGGBB`), cycled by slice index when
        # `#add_slice` is called without an explicit color.
        DEFAULT_COLORS = [
          0x40E0D0, 0xE0A040, 0xE04060, 0x60C040, 0x8060E0, 0x40A0E0,
        ]

        # The categorical slices, drawn clockwise from 12 o'clock in this order.
        getter slices : Array(Slice)

        # Inner-hole radius as a fraction of the outer radius (0..1). `0.0` (the
        # default) is a solid pie; a positive value hollows the center so the
        # slices read as a multi-color ring (a categorical donut).
        #
        # `getter` only: a plain `property` setter's generated `(Float64)`
        # overload would be *more specific* than the hand-written invalidating
        # `#inner_radius=(Number)` below, so the ordinary `pie.inner_radius =
        # 0.5` (a `Float64` literal) would dispatch to the silent generated
        # setter instead — verified empirically, this is the exact overload
        # shadowing pitfall `canvas_prop` exists to avoid. Keeping only the
        # `Number` overload as the sole setter closes the gap.
        getter inner_radius : Float64

        # Whether to draw the color-key legend over the bottom of the chart.
        getter? show_legend : Bool

        # Whether the legend appends each slice's percentage after its label.
        getter? show_percentages : Bool

        def initialize(
          slices : Array(Slice) = [] of Slice,
          @inner_radius : Float64 = 0.0,
          @show_legend : Bool = true,
          @show_percentages : Bool = true,
          type : Media::Type? = nil,
          glyph_mode : Media::Glyph::Mode = Media::Glyph::Mode::Braille,
          **box,
        )
          @slices = slices.dup
          super **box

          build_canvas(type, glyph_mode) { |p| paint_pie p }
        end

        # Appends a slice. Label-first argument order, matching the toolkit's
        # other add-verbs (`Gauge#add_item`, …). `color` accepts a native
        # `0xRRGGBB` int or a color name/`"#rrggbb"` string, defaulting to the
        # next entry of `DEFAULT_COLORS`, cycled by slice index.
        def add_slice(label : String, value : Number, color : Int32 | String? = nil) : Slice
          c = color || DEFAULT_COLORS[@slices.size % DEFAULT_COLORS.size]
          slice = Slice.new value.to_f, c, label
          @slices << slice
          invalidate_canvas
          slice
        end

        # Replaces all slices at once.
        def slices=(slices : Array(Slice)) : Array(Slice)
          @slices = slices.dup
          invalidate_canvas
          @slices
        end

        # Drops all slices.
        def clear_slices : Nil
          @slices.clear
          invalidate_canvas
        end

        def inner_radius=(v : Number) : Float64
          f = v.to_f
          return @inner_radius if f == @inner_radius
          @inner_radius = f
          invalidate_canvas
          @inner_radius
        end

        # Text-overlay setters: these change only what `#draw_legend` stamps
        # (the Canvas raster is untouched, so no `invalidate_canvas`), but a
        # plain `property?` setter schedules nothing and the change never
        # appears on an idle screen. `mark_dirty` registers damage and
        # schedules a frame.
        def show_legend=(v : Bool) : Bool
          return v if v == @show_legend
          @show_legend = v
          mark_dirty
          v
        end

        def show_percentages=(v : Bool) : Bool
          return v if v == @show_percentages
          @show_percentages = v
          mark_dirty
          v
        end

        def render(with_children = true)
          super
          draw_legend
        end

        # Sum of only the finite, positive slice values. A NaN slice value
        # survives `<= 0` (every comparison with NaN is false) and an
        # Infinite one passes it too, so an unfiltered `@slices.sum &.value`
        # lets one bad slice poison the shared total: in `#paint_pie` every
        # angle becomes NaN and `Painter#fill_ring`'s non-finite guard blanks
        # the whole chart; in `#draw_legend` the percentages are all
        # suppressed. Both call this instead of summing raw values so they
        # can never disagree.
        private def finite_positive_total : Float64
          @slices.sum { |s| s.value.finite? && s.value > 0 ? s.value : 0.0 }
        end

        private def paint_pie(p : Painter) : Nil
          cx, cy, ro = ring_geometry(p) || return
          ri = ro * @inner_radius.clamp(0.0, 0.95)

          total = finite_positive_total
          return if total <= 0

          # Accumulate angles clockwise from 12 o'clock; each slice sweeps its
          # share of 360°. Skip zero/negative/non-finite slices so they neither
          # advance the angle nor draw a degenerate wedge — a non-finite value
          # would otherwise poison `a0` (and every later slice) via `a1 = a0 +
          # 360.0 * slice.value / total`.
          a0 = 0.0
          @slices.each do |slice|
            next unless slice.value.finite? && slice.value > 0
            a1 = a0 + 360.0 * slice.value / total
            p.pen = slice.color
            p.fill_ring cx, cy, ri, ro, a0, a1 - a0
            a0 = a1
          end
        end

        private def draw_legend : Nil
          return unless show_legend?
          xi, xl, yi, yl = interior_coords || return
          return if xl - xi <= 0 || yl - yi <= 0

          total = finite_positive_total
          # One entry per slice, along the bottom rows (bottom-most = last slice),
          # so the legend reads top-to-bottom in slice order. Clip to the interior
          # so it never overwrites the top of the chart on a short widget.
          shown = @slices.size
          top = Math.max(yi, yl - shown)
          text_attr = style_to_attr(style, style.fg, style.bg)

          @slices.each_with_index do |slice, i|
            y = top + i
            break if y >= yl
            # Swatch in the slice's own color, then the label (+ optional %) in
            # the widget's foreground.
            put_cell xi, y, Scale::FULL, overlay_attr(slice.color), xi, xl
            text = slice.label
            if show_percentages? && total > 0
              # `total` is always finite here (`#finite_positive_total`
              # filters it), but `slice.value` itself may still be
              # non-finite (e.g. this very slice was excluded from `total`);
              # `frac` would then be NaN, on which `.round.to_i` raises
              # OverflowError in the render fiber — show 0% instead. The
              # clamp also keeps a huge finite share — possible when negative
              # slices shrink `total` — within Int32.
              frac = 100.0 * slice.value / total
              pct = frac.finite? ? frac.clamp(-999_999.0, 999_999.0).round.to_i : 0
              text = text.empty? ? "#{pct}%" : "#{text} #{pct}%"
            end
            put_text xi + 2, y, text, text_attr, xi, xl unless text.empty?
          end
        end
      end
    end
  end
end
