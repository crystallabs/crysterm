require "../box"
require "../../widget_effect_direct"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # "Plasma" effect — the slowly-undulating, rainbow-marbled field of demoscene
      # fame, as a self-contained, self-animating widget.
      #
      # Each cell's hue is a pure function of its position and the frame counter:
      # several sine waves (horizontal, vertical, diagonal, and a radial ripple
      # around the box centre) are summed and the total, normalised to `0.0..1.0`,
      # is mapped onto the colour wheel — so the whole area churns through a smooth,
      # seamless rainbow with no per-cell state to carry.
      #
      # It paints its interior straight into the window's cell buffer as packed
      # `Int64` attrs (each fg a direct `0xRRGGBB`, via `Colors.hsv_i`) — see
      # `Effect::Direct`. There is no tagged-content round-trip, so a full-window
      # field costs no per-cell `String` and no per-frame tag re-parse. It reads
      # its size lazily each frame (tracking resize and `%`-relative sizing) and
      # drives its own animation: call `#start` to spawn the render fiber and
      # `#stop` to halt it. `#step` (state only) is public so the effect can
      # instead be advanced from an external clock.
      #
      # ```
      # plasma = Widget::Effect::Plasma.new parent: window, width: "100%", height: "100%"
      # plasma.start
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![Plasma screenshot](../../../examples/widget/effect/plasma/plasma-capture5s.apng)
      # <!-- /widget-examples:capture -->
      class Plasma < Box
        include Effect::Direct

        # Glyph painted in every cell; only its colour varies. Defaults to the full
        # block, so the field reads as solid colour; a lighter shade (`▒`) or a dot
        # gives a more dithered, see-through look.
        property glyph : Char

        # Radians of horizontal wave added per column (its spatial frequency).
        property freq_x : Float64

        # Radians of vertical wave added per row (its spatial frequency).
        property freq_y : Float64

        # Radians of the radial ripple added per cell of distance from the centre.
        property freq_r : Float64

        # Radians every wave advances per frame (how fast the field churns).
        property speed : Float64

        # Hue degrees added per frame on top of the wave field (the colour-cycling
        # speed); `0` leaves the rainbow stationary in hue and only the shape moves.
        property hue_speed : Float64

        # HSV saturation of the field colours (`0.0..1.0`).
        property saturation : Float64

        # HSV value / brightness of the field colours (`0.0..1.0`).
        property brightness : Float64

        # Monotonically advancing frame counter. Int64 so it never wraps in any
        # realistic runtime; it only ever feeds `Math.sin` and a hue modulo.
        @frame : Int64 = 0

        def initialize(
          @glyph = '█',
          @interval = 0.07.seconds,
          @freq_x = 0.16,
          @freq_y = 0.13,
          @freq_r = 0.15,
          @speed = 0.1,
          @hue_speed = 2.0,
          @saturation = 1.0,
          @brightness = 1.0,
          **box,
        )
          super **box
        end

        # Stateless per frame — just advance the clock.
        def advance(w, h)
          @frame += 1
        end

        # No per-area state to (re)allocate.
        def resize(w, h)
        end

        # Glyph + packed `0xRRGGBB` colour for interior cell `{x, y}`.
        def cell(x, y, w, h) : {Char, Int32}
          f = @frame * @speed
          dx = x - w / 2.0
          dy = y - h / 2.0
          v = Math.sin(x * @freq_x + f) +
              Math.sin(y * @freq_y + f * 0.8) +
              Math.sin((x + y) * @freq_x * 0.5 + f * 0.6) +
              Math.sin(Math.sqrt(dx * dx + dy * dy) * @freq_r + f)
          # Four sines span -4.0..4.0; fold that into 0.0..1.0.
          t = (v + 4.0) / 8.0
          hue = (t * 360.0 + @frame * @hue_speed) % 360.0
          {@glyph, Colors.hsv_i(hue, @saturation, @brightness)}
        end
      end
    end
  end
end
