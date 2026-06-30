require "../box"
require "../../widget_effect_animated"
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
      # bar = Widget::Effect::CopperBar.new parent: window, top: 0, left: 0,
      #   width: "100%", height: 1
      # bar.start
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![CopperBar screenshot](../../../tests/widget/effect/copper_bar/copper_bar.5s.apng)
      # <!-- /widget-examples:capture -->
      class CopperBar < Box
        include Animated

        # Hue (degrees) of this bar at frame 0 — stagger several bars to spread
        # them around the color wheel.
        property hue_offset : Int32

        # Hue degrees advanced per frame (the cycling speed).
        property hue_speed : Int32

        # HSV saturation of the bar color (`0.0..1.0`).
        property saturation : Float64

        # HSV value / brightness of the bar color (`0.0..1.0`).
        property brightness : Float64

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
          mark_dirty # animation state/style changed; repaint under damage tracking
        end
      end
    end
  end
end
