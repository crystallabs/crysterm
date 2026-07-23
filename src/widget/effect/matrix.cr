require "../box"
require "../../widget_effect_direct"

module Crysterm
  class Widget
    # Namespace for self-contained, self-animating visual "effect" widgets —
    # showpiece animations (digital rain, etc.) that drive their own render
    # fiber and fill their own box.
    module Effect
      # "Matrix" digital-rain effect, as a self-contained, self-animating widget.
      #
      # Each column is a falling "drop": a bright head glyph trailing a tail that
      # fades from near-white down to deep green. Fills its own box (not
      # necessarily the whole window), reads its size lazily each frame, and so
      # tracks terminal resize and `%`-relative sizing automatically.
      #
      # Paints its interior straight into the window's cell buffer as packed
      # `Int64` attrs (each fg a direct `0xRRGGBB` value), avoiding a
      # tagged-content round-trip and per-frame tag re-parse. `#start` spawns the
      # render fiber, `#stop` halts it. `#step` (state only) is public so the
      # effect can instead be advanced from an external clock.
      #
      # ```
      # rain = Widget::Effect::Matrix.new parent: window, width: "100%", height: "100%"
      # rain.start
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![Matrix screenshot](../../../tests/widget/effect/matrix/matrix.5s.apng)
      # <!-- /widget-examples:capture -->
      class Matrix < Box
        include Effect::Direct

        # Default character pool; also the fallback if an empty pool is assigned.
        DEFAULT_POOL = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%&*+=?<>/\\|".chars

        # Characters rained down the window; one is sampled per lit cell per frame.
        #
        # An empty pool would crash the render fiber (`@pool.sample` raises), so an
        # empty assignment is rejected in favour of the default.
        # ameba:disable Lint/UselessAssign
        nonempty_property pool : Array(Char) = DEFAULT_POOL

        # Color of the leading ("head") glyph of every drop (a native `0xRRGGBB`
        # int, painted straight into the cell). For backwards compatibility the
        # setter also accepts a `"#rrggbb"`/named string.
        getter head_color : Int32 = 0xccffcc

        def head_color=(color : Int)
          @head_color = color.to_i32
        end

        def head_color=(color : String)
          @head_color = Colors.to_native(color)
        end

        # Per-column state, (re)built whenever the column count changes.
        @heads = [] of Float64
        @speeds = [] of Float64
        @lengths = [] of Int32

        def initialize(
          pool = DEFAULT_POOL,
          @interval = 0.07.seconds,
          head_color = 0xccffcc,
          **box,
        )
          self.pool = pool # reject empty in favour of the default
          self.head_color = head_color
          super **box
        end

        # (Re)initialize per-column state for *w* columns and *h* rows. Heads are
        # scattered over `[-h, h)` rather than only above the top, so roughly half
        # start already on-window: the first frame looks established immediately
        # instead of needing a warm-up.
        def resize(w : Int32, h : Int32)
          @heads = Array.new(w) { (rand(2 * h) - h).to_f }
          @speeds = Array.new(w) { 0.25 + rand * 0.7 }
          @lengths = Array.new(w) { 6 + rand(10) }
        end

        # Advance every drop; recycle a drop to a fresh negative offset, speed, and
        # length once its tail has fully fallen past the bottom.
        def advance(w : Int32, h : Int32)
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

        # Glyph + packed `0xRRGGBB` color for interior cell `{x, y}` (blank, with
        # the default fg, outside any drop's trail).
        def cell(x : Int32, y : Int32, w : Int32, h : Int32) : {Char, Int32}
          dist = @heads[x] - y
          if dist >= 0 && dist < @lengths[x]
            ch = @pool.sample
            if dist < 1
              {ch, head_color}
            else
              # Fade trail bright-to-deep-green: r=0x00, b=0x22, green ramps down
              # with distance from the head.
              frac = 1.0 - dist / @lengths[x]
              g = (60 + 180 * frac).to_i.clamp(0, 255)
              {ch, Colors.rgb(0, g, 0x22)}
            end
          else
            {' ', -1}
          end
        end
      end
    end
  end
end
