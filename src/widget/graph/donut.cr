require "../box"
require "./canvas"
require "../../widget_graph_painter"
require "../../widget_graph_scale"
require "../../mixin/ranged_value"

module Crysterm
  class Widget
    module Graph
      # A circular (ring) percentage indicator — blessed-contrib's `donut`,
      # reframed as a *radial* sibling of `ProgressBar`/`Gauge`. The ring is
      # drawn on a backend-agnostic `Graph::Canvas` (sixel/kitty where
      # available, else braille); the center readout is terminal text.
      #
      # The authoritative state is `#value` within `[#minimum, #maximum]`
      # (defaults `0`..`100`, so a value reads as its percentage). The filled arc
      # sweeps clockwise from 12 o'clock; the rest shows the `#track_color`.
      #
      # ```
      # d = Widget::Graph::Donut.new parent: s, width: 18, height: 9,
      #   value: 72, fill_color: 0x40E0D0, label: "CPU"
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![Donut screenshot](../../../tests/widget/graph/donut/donut.5s.apng)
      # <!-- /widget-examples:capture -->
      class Donut < Box
        include TextOverlay
        include InteriorCoords
        include RingGeometry
        # Float-valued `#span`/`#percent_of` helpers (shared with `Gauge`).
        include Mixin::PercentRange
        # `%p`/`%v`/`%m`/`%M` template expansion (shared with `Gauge`/`ProgressBar`).
        include Mixin::RangeText
        # Canvas ownership + the `canvas_prop` re-raster setter (shared with the
        # other radial/vector graph widgets).
        include Mixin::CanvasOwner

        property minimum : Float64
        property maximum : Float64

        # Filled-arc color and the unfilled-track color.
        property fill_color : Int32
        property track_color : Int32

        # Whether to draw the unfilled remainder as a (dim) full ring. Off by
        # default: the `Glyph`/braille backend is one color per cell, so a track
        # ring can't be color-distinguished from the fill. Turn it on for
        # truecolor backends (sixel/kitty), where the colors read distinctly.
        property? show_track : Bool

        # Ring thickness as a fraction of its radius (0..1).
        property thickness : Float64

        # Whether to draw the centered percentage readout.
        property? show_label : Bool

        # `sprintf`-ish format for the readout: `%p` percentage, `%v` value,
        # `%m` maximum, `%M` minimum.
        property format : String

        # Optional caption drawn under the percentage.
        property label : String

        # Ring-parameter setters: an assignment changes what `#paint_ring` draws,
        # so — like `#value=` — each must invalidate the Canvas raster and
        # schedule a render (the plain `property` setter did neither, leaving the
        # ring stale — old thickness/color/track — until an unrelated repaint).
        # `canvas_prop` (from `Mixin::CanvasOwner`) overrides the generated setter;
        # the getter from `property`/`property?` stays.
        canvas_prop minimum, Float64
        canvas_prop maximum, Float64
        canvas_prop fill_color, Int32
        canvas_prop track_color, Int32
        canvas_prop show_track, Bool
        canvas_prop thickness, Float64

        @value : Float64

        def initialize(
          value : Number = 0,
          @minimum : Number = 0.0,
          @maximum : Number = 100.0,
          @fill_color : Int32 = 0x40E0D0,
          @track_color : Int32 = 0x283038,
          @show_track : Bool = false,
          @thickness : Float64 = 0.45,
          @show_label : Bool = true,
          @format : String = "%p%",
          @label : String = "",
          type : Media::Type? = nil,
          glyph_mode : Media::Glyph::Mode = Media::Glyph::Mode::Braille,
          **box,
        )
          @minimum = @minimum.to_f
          @maximum = @maximum.to_f
          v = value.to_f
          # Non-finite input would survive `clamp` (NaN compares false) and
          # later crash the render fiber on `percent.round.to_i`; sanitize at
          # ingestion (as `PercentRange#assign_completable` does for `#value=`).
          v = @minimum unless v.finite?
          @value = v.clamp(@minimum, @maximum)
          super **box

          build_canvas(type, glyph_mode) { |p| paint_ring p }
        end

        def value : Float64
          @value
        end

        # Sets the value (clamped). Emits `Event::DoubleValueChange` on change and
        # `Event::Complete` at the maximum (shared `#value=` body from
        # `Mixin::PercentRange`, with Canvas invalidation as its post-change
        # action).
        def value=(v : Number) : Float64
          assign_completable(v) do
            # The ring geometry depends on `@value`, so the Canvas content is now
            # stale: mark it for repaint (it skips otherwise, under `@paint_dirty`).
            invalidate_canvas
          end
        end

        def percent : Float64
          percent_of @value
        end

        def render(with_children = true)
          super
          draw_center_label
        end

        private def paint_ring(p : Painter) : Nil
          cx, cy, ro = ring_geometry(p) || return
          ri = ro * (1.0 - @thickness.clamp(0.05, 1.0))

          # Optional full track ring (truecolor backends only), then the value
          # arc. With the track off (default), the unfilled remainder is empty
          # so the arc length reads as the percentage.
          if show_track?
            p.pen = @track_color
            p.fill_ring cx, cy, ri, ro, 0.0, 360.0
          end
          frac = percent / 100.0
          if frac > 0
            p.pen = @fill_color
            p.fill_ring cx, cy, ri, ro, 0.0, 360.0 * frac
          end
        end

        private def draw_center_label : Nil
          return unless show_label?
          xi, xl, yi, yl = interior_coords || return
          return if xl - xi <= 0 || yl - yi <= 0

          cy = yi + (yl - yi - 1) // 2
          pct = formatted_text
          put_centered pct, xi, xl, cy, overlay_attr(@fill_color)
          # `put_text` clips columns but not rows, so only draw the caption when
          # its row is still inside the interior — otherwise a 1-row interior
          # would stamp it onto the bottom border (or the widget below).
          unless @label.empty? || cy + 1 >= yl
            put_centered @label, xi, xl, cy + 1, sattr(style, style.fg, style.bg)
          end
        end

        # Cached center-readout text and the `{value, minimum, maximum, format}`
        # it was built for. `#draw_center_label` runs every frame; the four
        # chained `gsub`s only need to rerun when one of those inputs changes.
        @label_cache : String?
        @label_cache_key : Tuple(Float64, Float64, Float64, String)?

        private def formatted_text : String
          key = {@value, @minimum, @maximum, @format}
          if @label_cache_key != key || (cached = @label_cache).nil?
            @label_cache_key = key
            @label_cache = cached = format_range_text @format,
              percent.round.to_i.to_s, Scale.fmt(@value), Scale.fmt(@maximum), Scale.fmt(@minimum)
          end
          cached
        end
      end
    end
  end
end
