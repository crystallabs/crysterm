require "../box"
require "./canvas"

module Crysterm
  class Widget
    module Graph
      # A circular (ring) percentage indicator — blessed-contrib's `donut`,
      # reframed Qt-style as a *radial* sibling of `ProgressBar`/`Gauge` (and akin
      # to a single-slice QtCharts donut). The ring is drawn on a backend-agnostic
      # `Graph::Canvas` (sixel/kitty where available, else braille); the center
      # readout is terminal text.
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
      # ![Donut screenshot](../../../examples/widget/graph/donut/donut-capture5s.apng)
      # <!-- /widget-examples:capture -->
      class Donut < Box
        property minimum : Float64
        property maximum : Float64

        # Filled-arc color and the unfilled-track color.
        property fill_color : Int32
        property track_color : Int32

        # Whether to draw the unfilled remainder as a (dim) full ring. Off by
        # default: the default `Glyph`/braille backend is one color per cell, so
        # a track ring can't be color-distinguished from the fill and would just
        # make every value look 100% full. Turn it on for the truecolor graphics
        # backends (sixel/kitty), where the two colors read distinctly.
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

        @value : Float64

        # The drawing surface, built in `#initialize`. `canvas` raises if read
        # before construction completes; `canvas?` is the nilable variant.
        getter! canvas : Canvas

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
          @value = value.to_f.clamp(@minimum, @maximum)
          super **box

          cv = Canvas.new parent: self, type: type, glyph_mode: glyph_mode,
            top: 0, left: 0, right: 0, bottom: 0
          cv.on_paint { |p| paint_ring p }
          @canvas = cv
        end

        private def span : Float64
          s = @maximum - @minimum
          s <= 0 ? 1.0 : s
        end

        def value : Float64
          @value
        end

        # Sets the value (clamped). Emits `Event::DoubleValueChange` on change and
        # `Event::Complete` at the maximum.
        def value=(v : Number) : Float64
          v = v.to_f.clamp(@minimum, @maximum)
          return v if v == @value
          @value = v
          emit Crysterm::Event::DoubleValueChange, @value
          emit Crysterm::Event::Complete if @value == @maximum && @maximum > @minimum
          request_render
          @value
        end

        def percent : Float64
          ((@value - @minimum) / span * 100).clamp(0.0, 100.0)
        end

        def render(with_children = true)
          super
          draw_center_label
        end

        private def paint_ring(p : Painter) : Nil
          w = p.width
          h = p.height
          return if w <= 0 || h <= 0
          cx = w // 2
          cy = h // 2
          # Largest physically-round radius that fits (vertical extent is scaled
          # by pixel_aspect), with a small margin.
          aspect = p.pixel_aspect
          ro = Math.min(w / 2.0, (h / 2.0) / (aspect <= 0 ? 1.0 : aspect)) * 0.92
          return if ro <= 1
          ri = ro * (1.0 - @thickness.clamp(0.05, 1.0))

          # Optional full track ring (only useful on truecolor backends), then
          # the value arc. With the track off (default), the unfilled remainder
          # is genuinely empty so the arc length reads as the percentage.
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
          lp = @lpos || return
          xi = lp.xi + ileft
          xl = lp.xl - iright
          yi = lp.yi + itop
          yl = lp.yl - ibottom
          return if xl - xi <= 0 || yl - yi <= 0

          cy = yi + (yl - yi - 1) // 2
          pct = formatted_text
          put_centered pct, xi, xl, cy, sattr(style, @fill_color, style.bg)
          unless @label.empty?
            put_centered @label, xi, xl, cy + 1, sattr(style, style.fg, style.bg)
          end
        end

        private def formatted_text : String
          @format
            .gsub("%p", percent.round.to_i.to_s)
            .gsub("%v", Scale.fmt(@value))
            .gsub("%m", Scale.fmt(@maximum))
            .gsub("%M", Scale.fmt(@minimum))
        end

        private def put_centered(text : String, xi : Int32, xl : Int32, y : Int32, attr : Int64) : Nil
          return if text.empty?
          line = screen.lines[y]?
          return unless line
          x = xi + Math.max(0, (xl - xi - text.size) // 2)
          text.each_char_with_index do |ch, i|
            cx = x + i
            next if cx < xi || cx >= xl
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
