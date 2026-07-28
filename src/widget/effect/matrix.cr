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

        # Characters rained down the window; one is sampled per cell of the
        # glyph field (see `@glyphs`), re-rolled as drop heads pass.
        #
        # An empty pool would crash the render fiber (`@pool.sample` raises), so an
        # empty assignment is rejected in favour of the default.
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

        # Per-cell glyph field, column-major (`x * h + y`), sized with the
        # per-column state in `#resize`. Each cell shows a *stable* glyph:
        # re-rolled only when a drop's head passes over the cell, plus an
        # occasional per-column shimmer (`SHIMMER_CHANCE`). Sampling
        # `@pool.sample` per lit cell per frame instead re-randomized every
        # trail cell every frame, defeating damage tracking across the whole
        # rain area (R-91); with the field, a frame's damage is only the
        # trail edges, the head rows and the shimmered cells.
        @glyphs = [] of Char

        # Probability, per column per frame, of re-rolling one random cell
        # inside the drop's trail — keeps the classic Matrix glyph flicker
        # without touching more than a handful of cells per frame.
        SHIMMER_CHANCE = 0.05

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
          @glyphs = Array.new(w * h) { @pool.sample }
        end

        # Advance every drop, re-rolling the glyph field cells its head newly
        # covers; recycle a drop to a fresh negative offset, speed, and
        # length once its tail has fully fallen past the bottom.
        def advance(w : Int32, h : Int32)
          return if @heads.size != w
          w.times do |x|
            old_head = @heads[x].floor.to_i
            @heads[x] += @speeds[x]

            # Fresh glyph under each row the head newly reached this frame, so
            # the leading edge keeps its randomized look while cells behind it
            # stay frame-stable.
            new_head = @heads[x].floor.to_i
            y = Math.max(old_head + 1, 0)
            while y <= new_head && y < h
              @glyphs[x * h + y] = @pool.sample
              y += 1
            end

            # Occasional shimmer: rarely, re-roll one random cell inside the
            # trail.
            if rand < SHIMMER_CHANCE
              ty = new_head - rand(@lengths[x])
              @glyphs[x * h + ty] = @pool.sample if 0 <= ty < h
            end

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
            # Stable per-cell glyph (see `@glyphs`); the guarded fetch keeps a
            # transient size mismatch from raising mid-frame.
            ch = @glyphs[x * h + y]? || ' '
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
