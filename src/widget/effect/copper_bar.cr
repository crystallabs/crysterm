require "../box"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # A hue-cycling "copper" / raster bar — the scrolling colored band of
      # Amiga-demo fame, as a self-contained, self-animating widget.
      #
      # Extracted from the `cracktro.cr` feature demo: every frame it repaints its
      # whole background with the next hue, sweeping smoothly around the color
      # wheel. `hue_offset` staggers several bars apart (so a stack of them forms a
      # moving rainbow) and `hue_speed` sets how fast each cycles.
      #
      # Like `Effect::Matrix` and `Marquee`, it drives its own animation: call
      # `#start` to spawn the render fiber and `#stop` to halt it. `#step` (which
      # only repaints `style.bg`; it does not render or sleep) is public so the bar
      # can instead be advanced from an external clock — useful when several
      # effects must share one frame counter.
      #
      # ```
      # bar = Widget::Effect::CopperBar.new parent: screen, top: 0, left: 0,
      #   width: "100%", height: 1
      # bar.start
      # ```
      class CopperBar < Box
        # Delay between frames.
        property interval : Time::Span

        # Hue (degrees) of this bar at frame 0 — stagger several bars to spread
        # them around the color wheel.
        property hue_offset : Int32

        # Hue degrees advanced per frame (the cycling speed).
        property hue_speed : Int32

        # HSV saturation of the bar color (`0.0..1.0`).
        property saturation : Float64

        # HSV value / brightness of the bar color (`0.0..1.0`).
        property brightness : Float64

        # Frame loop; non-nil while running.
        @fiber : Fiber?
        protected property? running = false

        # Monotonically advancing frame counter. Int64 so it never wraps in any
        # realistic runtime; the hue is taken modulo 360.
        @frame : Int64 = 0

        def initialize(
          @interval = 0.07.seconds,
          @hue_offset = 0,
          @hue_speed = 9,
          @saturation = 1.0,
          @brightness = 1.0,
          **box,
        )
          super **box
        end

        # The bar's background color (native `0xRRGGBB`) for the current frame.
        def color : Int32
          Colors.hsv_i((@hue_offset + @frame * @hue_speed) % 360, @saturation, @brightness)
        end

        # Paint this frame's color onto `style.bg` and advance one frame.
        def step
          self.style.bg = color
          @frame += 1
        end

        # Start the animation: spawns a fiber that repaints, renders, and sleeps
        # `interval`, until `#stop`. Calling `#start` while already running is a
        # no-op.
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
