require "../box"
require "../../widget_effect_direct"

module Crysterm
  class Widget
    module Effect
      # "Fire" effect — the rising, flickering flame wall of demoscene fame, as a
      # self-contained, self-animating widget.
      #
      # The bottom row is reseeded with random "embers" every frame; every cell
      # above cools to a blend of the (hotter) cells just below it, so the field
      # settles into a flickering flame that fades as it climbs (a stronger `decay`
      # lets it reach higher before going dark). The `@heat` buffer is the only
      # state; it's rebuilt whenever the box size changes, so the effect tracks
      # resize and `%`-relative sizing automatically. Heat maps through a black →
      # red → orange → yellow → white ramp; cells below `ignition` render blank.
      #
      # It paints its interior straight into the window's cell buffer as packed
      # `Int64` attrs (each fg a direct `0xRRGGBB` value), so there is no
      # tagged-content round-trip and no per-frame tag re-parse. `#start` spawns
      # the render fiber, `#stop` halts it. `#step` (state only) is public so the
      # effect can instead be advanced from an external clock.
      #
      # ```
      # fire = Widget::Effect::Fire.new parent: window, width: "100%", height: "100%"
      # fire.start
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![Fire screenshot](../../../tests/widget/effect/fire/fire.5s.apng)
      # <!-- /widget-examples:capture -->
      class Fire < Box
        include Effect::Direct

        # Default glyph ramp; also the fallback if an empty ramp is assigned.
        DEFAULT_RAMP = [' ', '.', ':', '*', 'o', 'O', '#', '@']

        # Glyph ramp indexed by cell heat, coldest first. The first entry is used
        # for cells below `ignition` (so a leading space leaves cold cells blank);
        # the rest shade the flame from faint to solid.
        #
        # An empty ramp would crash the render fiber (`@ramp[0]` / `clamp`), so an
        # empty assignment is rejected in favour of the default.
        # ameba:disable Lint/UselessAssign
        nonempty_property ramp : Array(Char) = DEFAULT_RAMP

        # Fraction of heat that survives each upward step (`0.0..1.0`); the flame
        # decays by this factor per row, so higher = taller flames, lower = a
        # short fire that goes dark quickly. Clamped to `0.0..1.0`: a value above
        # `1.0` would amplify heat each row and grow `@heat` without bound.
        getter decay : Float64 = 0.9

        # :ditto:
        def decay=(value : Float64) : Float64
          @decay = value.clamp(0.0, 1.0)
        end

        # Lowest random ember heat seeded into the bottom row each frame; the source
        # flickers between `ignition` and `1.0`.
        property ignition : Float64

        # Optional colour override: `(heat) -> 0xRRGGBB`, where *heat* is
        # `0.0..1.0`. `nil` uses the built-in black → red → yellow → white ramp.
        property color : Proc(Float64, Int32)?

        # Per-area heat field, (re)built whenever the area's size changes. Flat
        # row-major buffer of `@cols * @rows` values in `0.0..1.0`.
        @heat = [] of Float64

        def initialize(
          ramp = DEFAULT_RAMP,
          @interval = 0.07.seconds,
          decay = 0.9,
          @ignition = 0.7,
          @color = nil,
          **box,
        )
          self.ramp = ramp   # reject empty in favour of the default
          self.decay = decay # clamp to 0.0..1.0
          super **box
        end

        # (Re)allocate the heat field for a *w*×*h* interior.
        def resize(w : Int32, h : Int32)
          @heat = Array.new(w * h, 0.0)
        end

        # Reseed the bottom row and cool each cell toward the (hotter) cells just
        # below it, working upward.
        def advance(w : Int32, h : Int32)
          return if w <= 0 || h <= 0 || @heat.size != w * h

          base = (h - 1) * w
          w.times { |x| @heat[base + x] = @ignition + rand * (1.0 - @ignition) }

          # The two edge columns (one fewer neighbour) are peeled out of the inner
          # loop, so the interior runs a branch-free 3-tap average. The size guard
          # above keeps every index in bounds, hence `unsafe_fetch`/`unsafe_put`.
          (h - 2).downto(0) do |y|
            row = y * w
            below = (y + 1) * w
            if w == 1
              @heat.unsafe_put(row, @heat.unsafe_fetch(below) * @decay)
              next
            end
            wm = w - 1
            # x == 0: self + right neighbour.
            s0 = @heat.unsafe_fetch(below) + @heat.unsafe_fetch(below + 1)
            @heat.unsafe_put(row, (s0 / 2) * @decay)
            # Interior columns 1..w-2: left + self + right.
            x = 1
            while x < wm
              b = below + x
              sum = @heat.unsafe_fetch(b - 1) + @heat.unsafe_fetch(b) + @heat.unsafe_fetch(b + 1)
              @heat.unsafe_put(row + x, (sum / 3) * @decay)
              x += 1
            end
            # x == w-1: left + self.
            se = @heat.unsafe_fetch(below + wm - 1) + @heat.unsafe_fetch(below + wm)
            @heat.unsafe_put(row + wm, (se / 2) * @decay)
          end
        end

        # Glyph + packed `0xRRGGBB` colour for interior cell `{x, y}` (blank, with
        # the default fg, for cold cells).
        def cell(x : Int32, y : Int32, w : Int32, h : Int32) : {Char, Int32}
          heat = @heat[y * w + x]? || 0.0
          if heat < @ignition * 0.15
            {@ramp[0], -1}
          else
            # A single-glyph ramp has no hot range (`clamp(1, 0)` would raise), so
            # index 0 is the only valid slot.
            idx = @ramp.size > 1 ? (heat * (@ramp.size - 1)).to_i.clamp(1, @ramp.size - 1) : 0
            {@ramp[idx], colorize(heat)}
          end
        end

        # Packed `0xRRGGBB` for a cell of the given *heat* (`0.0..1.0`): black at 0,
        # ramping up through red and yellow to white at 1.
        private def colorize(heat) : Int32
          if c = @color
            return c.call(heat)
          end
          r = ((heat * 3.0).clamp(0.0, 1.0) * 255).to_i
          g = ((heat * 3.0 - 1.0).clamp(0.0, 1.0) * 255).to_i
          b = ((heat * 3.0 - 2.0).clamp(0.0, 1.0) * 255).to_i
          Colors.rgb(r, g, b)
        end
      end
    end
  end
end
