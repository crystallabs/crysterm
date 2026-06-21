require "./box"
require "../colors"

module Crysterm
  class Widget
    # A horizontally scrolling line of text — a "marquee" / ticker.
    #
    # Extracted from the `cracktro.cr` feature demo's line scroller: every frame
    # it recomposes its single visible row as the `awidth`-wide window onto an
    # endlessly looping message. The message wraps modulo its own length, so any
    # trailing spaces in `text` become the gap between repeats and the loop is
    # seamless. It reads its size lazily each frame, so it tracks terminal resize
    # and `%`-relative widths automatically.
    #
    # Like `Effect::Matrix` and `Loading`, it drives its own animation: call
    # `#start` to spawn the render fiber and `#stop` to halt it.
    #
    # ```
    # ticker = Widget::Marquee.new parent: screen, top: 0, left: 0,
    #   width: "100%", height: 1, text: "BREAKING NEWS   ...   "
    # ticker.start
    # ```
    #
    # With `rainbow: true` each glyph carries its own hue, cycling across the
    # columns and over time — the classic demoscene color scroller.
    #
    # NOTE: tag parsing is forced on (the rainbow path emits `{#rrggbb-fg}`
    # tags), so a literal `{` in `text` would be interpreted as a tag.
    class Marquee < Box
      # Scroll direction of the text.
      enum Direction
        # Text travels right-to-left (the classic marquee). The newest character
        # enters at the right edge.
        Left
        # Text travels left-to-right; the newest character enters at the left edge.
        Right
      end

      # The message scrolled across the widget. Reassigning it is safe at any time.
      property text : String

      # Delay between frames.
      property interval : Time::Span

      # Direction the text travels.
      property direction : Direction

      # When true, each non-space glyph is tinted with a cycling hue instead of
      # the widget's foreground color.
      property? rainbow : Bool

      # Hue degrees added per column (the spatial rainbow spread) when `rainbow?`.
      property hue_spread : Int32

      # Hue degrees added per frame (the temporal cycling speed) when `rainbow?`.
      property hue_speed : Int32

      # Frame loop; non-nil while running.
      @fiber : Fiber?
      protected property? running = false

      # Monotonically advancing frame counter. Int64 so it never wraps in any
      # realistic runtime; indexing uses a (sign-safe) modulo of `text.size`.
      @frame : Int64 = 0

      def initialize(
        @text = "",
        @interval = 0.07.seconds,
        @direction : Direction = :left,
        @rainbow = false,
        @hue_spread = 7,
        @hue_speed = 8,
        **box,
      )
        super **box
        # The rainbow path emits `{#rrggbb-fg}` tags, so tag parsing must be on
        # regardless of what the caller passed.
        self.parse_tags = true
      end

      # Builds one frame: the `awidth`-wide window onto the looping message, then
      # advances by one column.
      def step
        w = awidth
        n = text.size
        return if w <= 0 || n == 0

        f = @frame
        self.content = String.build do |io|
          (0...w).each do |x|
            # For `:left`, column x shows text[f + x] so that as f grows the row
            # shifts left; `:right` is the mirror. Crystal's `%` follows the
            # divisor's sign, so the result is always a valid (non-negative) index.
            idx = (direction.left? ? f + x : f - x) % n
            ch = text[idx]
            if rainbow? && ch != ' '
              io << '{' << Colors.hsv((x * @hue_spread + f * @hue_speed) % 360) << "-fg}" << ch << "{/}"
            else
              io << ch
            end
          end
        end

        @frame += 1
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
