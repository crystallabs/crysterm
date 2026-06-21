require "../box"

module Crysterm
  class Widget
    # Namespace for self-contained, self-animating visual "effect" widgets —
    # showpiece animations (digital rain, etc.) that drive their own render
    # fiber and fill their own box.
    module Effect
      # "Matrix" digital-rain effect, as a self-contained, self-animating widget.
      #
      # Extracted from the `matrix.cr` feature demo: it recomposes its whole area
      # every frame into a single tag-parsed string, where each glyph carries its
      # own `{#rrggbb-fg}` TrueColor tag so the trails fade smoothly from a bright
      # head down to deep green. It fills its own box (not necessarily the whole
      # screen), reads its size lazily each frame, and so tracks terminal resize
      # and `%`-relative sizing automatically.
      #
      # Animation is driven by the widget itself: call `#start` to spawn the
      # render fiber and `#stop` to halt it (mirroring `Widget::Loading`).
      #
      # ```
      # rain = Widget::Effect::Matrix.new parent: screen, width: "100%", height: "100%"
      # rain.start
      # ```
      class Matrix < Box
        # Characters rained down the screen; one is sampled per lit cell per frame.
        property pool : Array(Char)

        # Delay between frames.
        property interval : Time::Span

        # Color of the leading ("head") glyph of every drop.
        property head_color : String

        # Frame loop; non-nil while running.
        @fiber : Fiber?
        protected property? running = false

        # Per-column state, (re)built lazily whenever the column count changes.
        @cols = 0
        @heads = [] of Float64
        @speeds = [] of Float64
        @lengths = [] of Int32

        def initialize(
          @pool = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%&*+=?<>/\\|".chars,
          @interval = 0.07.seconds,
          @head_color = "#ccffcc",
          **box,
        )
          # The fading trail is emitted as `{#rrggbb-fg}` tags, so tag parsing
          # must be on regardless of what the caller passed.
          super **box
          self.parse_tags = true
        end

        # (Re)initialize per-column state for *w* columns and *h* rows. Heads start
        # at random negative offsets so the rain doesn't all begin at the top.
        private def reset_columns(w, h)
          @cols = w
          @heads = Array.new(w) { -rand(0..h).to_f }
          @speeds = Array.new(w) { 0.25 + rand * 0.7 }
          @lengths = Array.new(w) { 6 + rand(10) }
        end

        # Builds one frame of rain sized to the current box and advances the drops.
        def step
          w = awidth
          h = aheight
          return if w <= 0 || h <= 0
          reset_columns w, h if w != @cols

          self.content = String.build do |io|
            h.times do |y|
              w.times do |x|
                dist = @heads[x] - y
                if dist >= 0 && dist < @lengths[x]
                  ch = @pool.sample
                  if dist < 1
                    io << '{' << @head_color << "-fg}" << ch << "{/}"
                  else
                    frac = 1.0 - dist / @lengths[x]
                    g = (60 + 180 * frac).to_i.clamp(0, 255)
                    io << ("{#00%02x22-fg}" % g) << ch << "{/}"
                  end
                else
                  io << ' '
                end
              end
              io << '\n' unless y == h - 1
            end
          end

          w.times do |x|
            @heads[x] += @speeds[x]
            if @heads[x] - @lengths[x] > h
              @heads[x] = -rand(0..h).to_f
              @speeds[x] = 0.25 + rand * 0.7
              @lengths[x] = 6 + rand(10)
            end
          end
        end

        # Start the animation: spawns a fiber that recomposes a frame, renders, and
        # sleeps `interval`, until `#stop`. Calling `#start` while already running
        # is a no-op.
        def start
          return if running?
          self.running = true
          @fiber = Fiber.new do
            loop do
              break unless running?
              step
              screen.render
              sleep @interval
            end
          end.enqueue
        end

        # Stop the animation. The fiber exits on its next iteration.
        def stop
          self.running = false
        end

        def toggle
          running? ? stop : start
        end
      end
    end
  end
end
