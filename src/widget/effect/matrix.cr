require "../box"
require "./direct"

module Crysterm
  class Widget
    # Namespace for self-contained, self-animating visual "effect" widgets —
    # showpiece animations (digital rain, etc.) that drive their own render
    # fiber and fill their own box.
    module Effect
      # "Matrix" digital-rain effect, as a self-contained, self-animating widget.
      #
      # Each column is a falling "drop": a bright head glyph trailing a tail that
      # fades from near-white down to deep green. It fills its own box (not
      # necessarily the whole screen), reads its size lazily each frame, and so
      # tracks terminal resize and `%`-relative sizing automatically.
      #
      # It paints its interior straight into the screen's cell buffer as packed
      # `Int64` attrs (each fg a direct `0xRRGGBB` value) — see `Effect::Direct` —
      # so there is no tagged-content round-trip and no per-frame tag re-parse.
      # Animation is driven by the widget itself: call `#start` to spawn the render
      # fiber and `#stop` to halt it (mirroring `Widget::Loading`). `#step` (state
      # only) is public so the effect can instead be advanced from an external
      # clock.
      #
      # ```
      # rain = Widget::Effect::Matrix.new parent: screen, width: "100%", height: "100%"
      # rain.start
      # ```
      class Matrix < Box
        include Effect::Direct

        # Characters rained down the screen; one is sampled per lit cell per frame.
        property pool : Array(Char)

        # Color of the leading ("head") glyph of every drop (a native `0xRRGGBB`
        # int, painted straight into the cell). For backwards compatibility the
        # setter also accepts a `"#rrggbb"`/named string.
        getter head_color : Int32 = 0xccffcc

        def head_color=(color : Int)
          @head_color = color.to_i32
        end

        def head_color=(color : String)
          @head_color = Colors.convert(color).to_i32
        end

        # Per-column state, (re)built whenever the column count changes.
        @heads = [] of Float64
        @speeds = [] of Float64
        @lengths = [] of Int32

        def initialize(
          @pool = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%&*+=?<>/\\|".chars,
          @interval = 0.07.seconds,
          head_color = 0xccffcc,
          **box,
        )
          self.head_color = head_color
          super **box
        end

        # (Re)initialize per-column state for *w* columns and *h* rows. Heads start
        # at random negative offsets so the rain doesn't all begin at the top.
        def resize(w, h)
          @heads = Array.new(w) { -rand(0..h).to_f }
          @speeds = Array.new(w) { 0.25 + rand * 0.7 }
          @lengths = Array.new(w) { 6 + rand(10) }
        end

        # Advance every drop; recycle a drop to a fresh negative offset, speed, and
        # length once its tail has fully fallen past the bottom.
        def advance(w, h)
          return if @heads.size != w
          w.times do |x|
            @heads[x] += @speeds[x]
            if @heads[x] - @lengths[x] > h
              @heads[x] = -rand(0..h).to_f
              @speeds[x] = 0.25 + rand * 0.7
              @lengths[x] = 6 + rand(10)
            end
          end
        end

        # Glyph + packed `0xRRGGBB` colour for interior cell `{x, y}` (blank, with
        # the default fg, for cells outside any drop's trail).
        def cell(x, y, w, h) : {Char, Int32}
          dist = @heads[x] - y
          if dist >= 0 && dist < @lengths[x]
            ch = @pool.sample
            if dist < 1
              {ch, head_color}
            else
              # Fade the trail from bright to deep green: r=0x00, b=0x22, with the
              # green channel ramping down with distance from the head.
              frac = 1.0 - dist / @lengths[x]
              g = (60 + 180 * frac).to_i.clamp(0, 255)
              {ch, (g << 8) | 0x22}
            end
          else
            {' ', -1}
          end
        end
      end
    end
  end
end
