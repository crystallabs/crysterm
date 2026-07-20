require "../box"
require "../../widget_effect_direct"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # A hue-cycling "copper" / raster bar — the scrolling colored band of
      # Amiga-demo fame, as a self-contained, self-animating widget.
      #
      # Every frame it repaints its background with the next hue. `hue_offset`
      # staggers several bars apart (forming a moving rainbow) and `hue_speed`
      # sets how fast each cycles.
      #
      # Drives its own animation: `#start` spawns the render fiber, `#stop` halts
      # it. `#step` (repaints `style.bg` only; no render/sleep) is public so the
      # bar can instead be advanced from an external clock shared by several
      # effects.
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

        # Hue degrees advanced per frame.
        property hue_speed : Int32

        # HSV saturation of the bar color (`0.0..1.0`).
        property saturation : Float64

        # HSV value / brightness of the bar color (`0.0..1.0`).
        property brightness : Float64

        # Monotonically advancing frame counter. Int64 so it never wraps; hue is
        # taken modulo 360.
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
          Colors.hsv_i(((@frame * @hue_speed + @hue_offset) % 360).to_i32, @saturation, @brightness)
        end

        # Paint this frame's color onto `style.bg` and advance one frame.
        def step
          self.style.bg = color
          @frame += 1
          mark_dirty
        end
      end
    end
  end
end
