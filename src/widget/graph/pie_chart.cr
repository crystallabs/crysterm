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
      # pie.add_slice 50, 0x40E0D0, "web"
      # pie.add_slice 30, 0xE0A040, "db"
      # pie.add_slice 20, 0xE04060, "cache"
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![PieChart screenshot](../../../tests/widget/graph/pie_chart/pie_chart.5s.apng)
      # <!-- /widget-examples:capture -->
      class PieChart < Box
        include TextOverlay
        include InteriorCoords
        include RingGeometry

        # One categorical wedge: its `value` (share of the total), fill `color`
        # (`0xRRGGBB`) and legend `label`.
        record Slice, value : Float64, color : Int32, label : String

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
        property inner_radius : Float64

        # Whether to draw the color-key legend over the bottom of the chart.
        property? show_legend : Bool

        # Whether the legend appends each slice's percentage after its label.
        property? show_percentages : Bool

        # The drawing surface, built in `#initialize`. `canvas` raises if read
        # before construction completes; `canvas?` is the nilable variant.
        getter! canvas : Canvas

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

          cv = Canvas.new parent: self, type: type, glyph_mode: glyph_mode,
            top: 0, left: 0, right: 0, bottom: 0
          cv.on_paint { |p| paint_pie p }
          @canvas = cv
        end

        # Appends a slice. `color` defaults to the next entry of `DEFAULT_COLORS`
        # (cycled by slice index). Repaints the chart on change (Qt's
        # property-change-triggers-update).
        def add_slice(value : Number, color : Int32? = nil, label : String = "") : Slice
          color ||= DEFAULT_COLORS[@slices.size % DEFAULT_COLORS.size]
          slice = Slice.new value.to_f, color, label
          @slices << slice
          invalidate
          slice
        end

        # Replaces all slices at once.
        def slices=(slices : Array(Slice)) : Array(Slice)
          @slices = slices.dup
          invalidate
          @slices
        end

        # Drops all slices.
        def clear_slices : Nil
          @slices.clear
          invalidate
        end

        def inner_radius=(v : Number) : Float64
          @inner_radius = v.to_f
          invalidate
          @inner_radius
        end

        def render(with_children = true)
          super
          draw_legend
        end

        # Marks the Canvas content stale and schedules a render, so a data or
        # geometry change repaints (the Canvas skips otherwise, under its own
        # `@paint_dirty`).
        private def invalidate : Nil
          canvas?.try &.invalidate_paint
          request_render
        end

        private def paint_pie(p : Painter) : Nil
          cx, cy, ro = ring_geometry(p) || return
          ri = ro * @inner_radius.clamp(0.0, 0.95)

          total = @slices.sum &.value
          return if total <= 0

          # Accumulate angles clockwise from 12 o'clock; each slice sweeps its
          # share of 360°. Skip zero/negative slices so they neither advance the
          # angle nor draw a degenerate wedge.
          a0 = 0.0
          @slices.each do |slice|
            next if slice.value <= 0
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

          total = @slices.sum &.value
          # One entry per slice, along the bottom rows (bottom-most = last slice),
          # so the legend reads top-to-bottom in slice order. Clip to the interior
          # so it never overwrites the top of the chart on a short widget.
          shown = @slices.size
          top = Math.max(yi, yl - shown)
          text_attr = sattr(style, style.fg, style.bg)

          @slices.each_with_index do |slice, i|
            y = top + i
            break if y >= yl
            # Swatch in the slice's own color, then the label (+ optional %) in
            # the widget's foreground — mirroring how `Donut` mixes attrs across
            # its overlay `put` calls.
            put_cell xi, y, Scale::FULL, overlay_attr(slice.color), xi, xl
            text = slice.label
            if show_percentages? && total > 0
              pct = (100.0 * slice.value / total).round.to_i
              text = text.empty? ? "#{pct}%" : "#{text} #{pct}%"
            end
            put_text xi + 2, y, text, text_attr, xi, xl unless text.empty?
          end
        end
      end
    end
  end
end
