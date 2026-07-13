require "./box"

module Crysterm
  class Widget
    # A smooth color gradient painted across the widget's area — useful as a
    # backdrop, header, or a strip of color swatches.
    #
    # Colors come from `colors:` (gradient *stops*, interpolated in RGB across
    # the axis). With **no** stops it renders a full **HSV rainbow** sweep, which
    # is the common case (and what the `truecolor`/`styling` demos use).
    #
    # `phase` offsets the gradient along its axis and wraps, so advancing it
    # *scrolls* / *cycles* the colors. That advance can be driven three ways via
    # `animate:`:
    #
    # * `false` (default) — static; `phase` only changes if you set it.
    # * `true` — the widget owns a private `Timer` and advances `phase` by
    #   `speed` every `interval`.
    # * a `Timer` — sync to a shared clock, so several widgets animate in
    #   lockstep off one fiber.
    #
    # ```
    # # static rainbow backdrop
    # Widget::Gradient.new parent: s, width: "100%", height: "100%"
    #
    # # animated hue-cycling strip, synced to a shared timer
    # clock = Crysterm::Timer.new 0.1.seconds
    # Widget::Gradient.new parent: s, width: 76, height: 2, animate: clock, speed: 0.03
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Gradient screenshot](../../tests/widget/gradient/gradient.5s.apng)
    # <!-- /widget-examples:capture -->
    class Gradient < Box
      enum Direction
        Horizontal # color varies across columns (left → right)
        Vertical   # color varies down rows (top → bottom)
      end

      # Gradient stops as native colors. Empty ⇒ HSV rainbow sweep.
      getter stops : Array(Int32)

      # Axis the color varies along.
      getter direction : Direction

      # Offset along the gradient (wraps); animating it scrolls/cycles the colors.
      getter phase : Float64

      # Number of full gradient repetitions across the axis.
      getter cycles : Float64

      # Phase advance applied on each animation tick.
      property speed : Float64

      # Setters that change the rendered appearance schedule a repaint (Qt's
      # property-changes-trigger-update principle), so e.g. `gradient.phase = …`
      # from an external clock actually scrolls the colors.
      def stops=(@stops : Array(Int32))
        mark_dirty
      end

      def direction=(@direction : Direction)
        mark_dirty
      end

      def phase=(@phase : Float64)
        mark_dirty
      end

      def cycles=(@cycles : Float64)
        mark_dirty
      end

      # The timer driving the animation (own or shared), if any.
      getter timer : Timer?

      @own_timer : Timer?

      # This widget's subscription to `@timer`'s `Tick`, kept so `#destroy` can
      # remove it. For a *shared* `animate:` clock the timer outlives the widget,
      # so without this the closure would keep mutating a destroyed widget on
      # every tick and pin it forever. A `Subscription` captures the timer it was
      # installed on, so `#off` reaches that exact (possibly shared) clock.
      @tick_sub = ::Crysterm::Subscription.new

      def initialize(
        colors : Array = [] of String,
        direction : Direction | Symbol = :horizontal,
        @phase : Float64 = 0.0,
        @cycles : Float64 = 1.0,
        @speed : Float64 = 0.02,
        animate : Bool | Timer = false,
        interval : Time::Span = 0.1.seconds,
        **box,
      )
        @stops = colors.map { |c| Colors.convert(c).as(Int32) }
        @direction = direction.is_a?(Symbol) ? Direction.parse(direction.to_s) : direction

        super **box

        @timer = case animate
                 in Timer then animate
                 in Bool  then animate ? (@own_timer = Timer.new(interval)) : nil
                 end
        @timer.try do |t|
          @tick_sub.on(t, Crysterm::Event::Tick) do
            @phase += @speed
            request_render
          end
        end
      end

      # Stops the privately-owned animation timer (if any) so its tick fiber
      # doesn't outlive the widget. A shared `animate:` timer belongs to the
      # caller and is left running.
      def destroy
        # Unsubscribe from the (possibly shared) clock so its tick fiber stops
        # mutating this destroyed widget, then stop a privately-owned timer.
        @tick_sub.off
        @own_timer.try &.stop
        super
      end

      # Native color at normalized position *t* (in `0.0...1.0`) along the axis,
      # accounting for `phase` and `cycles`.
      def color_at(t : Float64) : Int32
        p = t * @cycles + @phase
        if @stops.empty?
          Colors.hsv_i(p * 360.0)
        elsif @stops.size == 1
          @stops[0]
        else
          pf = p - p.floor # wrapped into 0.0...1.0
          # A position landing exactly on a cycle boundary (whole `p`, e.g. the
          # inclusive endpoint `t == 1.0` of a single-cycle gradient) is the
          # gradient's *end*, not the start of the next repeat: keep it at 1.0 so
          # the final stop's exact color is painted rather than wrapping to the
          # first stop.
          pf = 1.0 if pf == 0.0 && p > 0.0
          seg = pf * (@stops.size - 1)
          i = seg.to_i
          i = @stops.size - 2 if i > @stops.size - 2
          frac = seg - i
          Colors.mix @stops[i], @stops[i + 1], 1.0 - frac
        end
      end

      def render
        # Interior inset (border kept intact), mirroring `Widget::ProgressBar`.
        with_inner_coords do |xi, xl, yi, yl|
          next if xl <= xi || yl <= yi

          # Only the bg color varies from cell to cell; the style flags and the
          # foreground are invariant across the whole gradient, so compute the
          # base word (flags + fg, Opaque alpha from `sattr`) once and repack
          # just the bg per cell via `Attr.with_bg` instead of running `sattr`'s
          # full flag derivation every time.
          base = sattr style, style.fg, style.bg

          if @direction.horizontal?
            # Inclusive endpoints: with W columns, the divisor is W-1 so the last
            # column maps to t = 1.0 and paints the final stop's exact color. A
            # single-column bar has no span to divide, so it just shows t = 0.
            span = (xl - xi).to_f
            den = span > 1 ? span - 1 : 1.0
            (xi...xl).each do |x|
              attr = Attr.with_bg base, Attr.pack_color(color_at((x - xi) / den))
              window.fill_region attr, ' ', x, x + 1, yi, yl
            end
          else
            span = (yl - yi).to_f
            den = span > 1 ? span - 1 : 1.0
            (yi...yl).each do |y|
              attr = Attr.with_bg base, Attr.pack_color(color_at((y - yi) / den))
              window.fill_region attr, ' ', xi, xl, y, y + 1
            end
          end
        end
      end
    end
  end
end
