require "../box"
require "../../widget_effect_direct"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # "Plasma" effect — an undulating, rainbow-marbled field of demoscene fame,
      # as a self-contained, self-animating widget.
      #
      # Each cell's hue is a pure function of its position and the frame counter:
      # several sine waves (horizontal, vertical, diagonal, and a radial ripple
      # around the box centre) are summed and the total, normalised to `0.0..1.0`,
      # is mapped onto the colour wheel — a seamless rainbow with no per-cell
      # state to carry.
      #
      # Paints its interior straight into the window's cell buffer as packed
      # `Int64` attrs (each fg a direct `0xRRGGBB`, via `Colors.hsv_i`) — see
      # `Effect::Direct` — avoiding a tagged-content round-trip and per-frame tag
      # re-parse. Reads its size lazily each frame (tracking resize and
      # `%`-relative sizing). Call `#start` to spawn the render fiber and
      # `#stop` to halt it. `#step` (state only) is public so the effect can
      # instead be advanced from an external clock.
      #
      # ```
      # plasma = Widget::Effect::Plasma.new parent: window, width: "100%", height: "100%"
      # plasma.start
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![Plasma screenshot](../../../tests/widget/effect/plasma/plasma.5s.apng)
      # <!-- /widget-examples:capture -->
      class Plasma < Box
        include Effect::Direct

        # Glyph painted in every cell; only its colour varies. Defaults to the
        # full block; a lighter shade (`▒`) or a dot gives a dithered look.
        property glyph : Char

        # Radians of horizontal wave added per column (its spatial frequency).
        property freq_x : Float64

        # Radians of vertical wave added per row (its spatial frequency).
        property freq_y : Float64

        # Radians of the radial ripple added per cell of distance from the centre.
        property freq_r : Float64

        # Radians every wave advances per frame (how fast the field churns).
        property speed : Float64

        # Hue degrees added per frame on top of the wave field; `0` leaves the
        # rainbow stationary in hue and only the shape moves.
        property hue_speed : Float64

        # HSV saturation of the field colours (`0.0..1.0`).
        property saturation : Float64

        # HSV value / brightness of the field colours (`0.0..1.0`).
        property brightness : Float64

        # Monotonically advancing frame counter. Int64 so it never wraps; only
        # ever feeds `Math.sin` and a hue modulo.
        @frame : Int64 = 0

        # Precomputed radial distance from the box centre for each interior cell
        # (`i = y*w + x`) — a pure function of position and size, so the per-cell
        # `Math.sqrt` is hoisted out of the hot path.
        @dist = [] of Float64

        # Per-frame sine tables: the three wave terms that depend only on `x`,
        # only on `y`, or only on `x+y` become a single lookup in `#cell` instead
        # of a `Math.sin`. `@sin_d` is indexed by `x+y` (`0...(w+h)`). Only the
        # radial term stays per-cell.
        @sin_x = [] of Float64
        @sin_y = [] of Float64
        @sin_d = [] of Float64

        # Frame the sine tables currently hold (`-1` = never filled). The tables
        # are refilled lazily on the first `#cell` of a new frame, so they stay
        # correct even when `#cell` is driven directly (bypassing the
        # `#resize`/`#advance` render lifecycle), and are filled only once per
        # painted frame.
        @wave_frame : Int64 = -1

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

        # Advance the clock. The per-frame sine tables are refilled lazily on the
        # first `#cell` of the new frame (see `#ensure_tables`), so a frame that
        # is never painted does no table work.
        def advance(w, h)
          @frame += 1
        end

        # `Effect::Direct` hook: (re)build the distance table and (re)size the
        # sine tables for a *w*×*h* interior. The sine values are (re)filled on
        # next use.
        def resize(w, h)
          build_tables w, h
        end

        # Glyph + packed `0xRRGGBB` colour for interior cell `{x, y}`. The three
        # position-separable wave terms are table lookups; only the radial term
        # (which folds in the per-frame phase `f`) is still a `Math.sin`, over the
        # precomputed distance. Summation order matches the original exactly.
        def cell(x, y, w, h) : {Char, Int32}
          ensure_tables w, h
          f = @frame * @speed
          v = @sin_x[x] + @sin_y[y] + @sin_d[x + y] +
              Math.sin(@dist[y * w + x] * @freq_r + f)
          # Four sines span -4.0..4.0; fold that into 0.0..1.0.
          t = (v + 4.0) / 8.0
          hue = (t * 360.0 + @frame * @hue_speed) % 360.0
          {@glyph, Colors.hsv_i(hue, @saturation, @brightness)}
        end

        # Ensure the distance table matches the interior size and the sine tables
        # hold the current frame, rebuilding/refilling only when the size or frame
        # changed. Keeps `#cell` a pure function of (position, size, frame, params)
        # even when driven directly (tests / an external clock) without the normal
        # `#resize`+`#advance` lifecycle, while still filling the tables just once
        # per painted frame on the hot path.
        private def ensure_tables(w, h)
          build_tables(w, h) if @dist.size != w * h || @sin_x.size != w || @sin_y.size != h
          if @wave_frame != @frame
            fill_wave_tables w, h
            @wave_frame = @frame
          end
        end

        # (Re)compute `@dist` and (re)size the sine tables for a *w*×*h* interior;
        # marks the sine tables stale so the next `#ensure_tables` refills them.
        private def build_tables(w, h)
          @dist = Array(Float64).new(w * h) do |i|
            x = i % w
            y = i // w
            dx = x - w / 2.0
            dy = y - h / 2.0
            Math.sqrt(dx * dx + dy * dy)
          end
          @sin_x = Array(Float64).new(w, 0.0)
          @sin_y = Array(Float64).new(h, 0.0)
          @sin_d = Array(Float64).new(w + h, 0.0)
          @wave_frame = -1
        end

        # Fill the three sine tables at the current frame. Bit-identical to the
        # inline `Math.sin(...)` terms `#cell` used to compute: the same
        # expressions, evaluated once per row/column/diagonal instead of once per
        # cell.
        private def fill_wave_tables(w, h)
          f = @frame * @speed
          w.times { |x| @sin_x[x] = Math.sin(x * @freq_x + f) }
          h.times { |y| @sin_y[y] = Math.sin(y * @freq_y + f * 0.8) }
          (w + h).times { |k| @sin_d[k] = Math.sin(k * @freq_x * 0.5 + f * 0.6) }
        end
      end
    end
  end
end
