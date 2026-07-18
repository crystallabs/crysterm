module Crysterm
  class Widget
    # Progress bar element, modeled after Qt's `QProgressBar`.
    #
    # The authoritative state is `#value`, an integer within the inclusive range
    # `[#minimum, #maximum]`. The visually filled portion (`#percent`, a 0..100
    # percentage) is derived from where `value` sits in that range, so callers may
    # drive the bar either in domain units (`bar.value = 42`, range 0..200) or in
    # plain percentages (`bar.percent = 50`) — both stay consistent.
    #
    # <!-- widget-examples:capture v1 -->
    # ![ProgressBar screenshot](../../tests/widget/progressbar/progressbar.5s.apng)
    # <!-- /widget-examples:capture -->
    class ProgressBar < Input
      include Mixin::RangeText
      include Mixin::TrackGeometry

      # Lower/upper bounds of the value range (inclusive), like Qt's
      # `minimum`/`maximum`. With the defaults (0..100) a value equals its
      # percentage. Setting `maximum == minimum` yields a "busy"/empty bar.
      getter minimum : Int32 = 0
      getter maximum : Int32 = 100

      # Sets the lower bound (Qt's `setMinimum`), re-clamping the value into the
      # new range and repainting.
      def minimum=(v : Int32) : Int32
        set_range v, @maximum
        @minimum
      end

      # Sets the upper bound (Qt's `setMaximum`), re-clamping the value into the
      # new range and repainting.
      #
      # Mirrors Qt's `setMaximum` (`setRange(qMin(minimum, maximum), maximum)`):
      # a new maximum below the current minimum pulls the minimum *down* with it,
      # so the new bound always wins rather than being collapsed back up by
      # `#set_range`'s inverted-range guard.
      def maximum=(v : Int32) : Int32
        set_range Math.min(@minimum, v), v
        @maximum
      end

      # Sets both bounds at once (Qt's `setRange`). `#percent` and the
      # `%p`/`%m`/`%M` text derive from the range, so this re-clamps the current
      # value into the new range and schedules a repaint. Never stores an
      # inverted range.
      def set_range(min : Int32, max : Int32) : Nil
        max = min if max < min
        return if min == @minimum && max == @maximum
        @minimum = min
        @maximum = max
        # Re-clamp without emitting `Event::Completed`: shrinking the range onto
        # the current value is a reconfiguration, not a completion — `Completed`
        # fires only when the value *rises* to `maximum`.
        set_value @value.clamp(@minimum, @maximum), complete: false
        request_render
      end

      # Sets the inclusive `[minimum, maximum]` range from a `Range` (Qt's
      # `setRange`), so a bar takes one the same way a `Slider`/`Dial` does. An
      # exclusive range (`begin...end`) covers `begin..end - 1`, matching
      # Crystal's own `Range` semantics; a degenerate empty exclusive range
      # (`n...n`) collapses to the single value `n` instead of inverting.
      #
      # Must stay byte-identical to `Mixin::RangedValue#range=`; ProgressBar can't
      # include that mixin, so update the two in lockstep.
      def range=(r : ::Range(Int32, Int32)) : ::Range(Int32, Int32)
        max = r.exclusive? ? Math.max(r.begin, r.end - 1) : r.end
        set_range r.begin, max
        r
      end

      # Amount a single key press (or default `#progress`) moves the value by,
      # in domain units. Qt's `QAbstractSlider#singleStep`.
      property single_step : Int32 = 5

      property orientation : Tput::Orientation = :horizontal

      # Whether to draw the textual indicator (see `#format`) over the bar,
      # like Qt's `QProgressBar#textVisible`.
      property? text_visible : Bool = false

      # Template for the text drawn when `#text_visible?`. Recognized placeholders,
      # matching Qt's `QProgressBar#format`: `%p` percentage, `%v` current value,
      # `%m` maximum, `%M` minimum.
      property format : String = "%p%"

      # XXX Change this to enabled? later.
      property? keys : Bool = true
      property? mouse : Bool = false

      @value : Int32 = 0

      def initialize(
        percent : Int32? = nil,
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @single_step = 5,
        @text_visible = false,
        @format = "%p%",
        @keys = true,
        @mouse = false,
        @orientation = @orientation,
        **input,
      )
        super **input

        # Never start with an inverted range: `#percent`/`#span`/the `%p` text all
        # assume `minimum <= maximum`, and this constructor path bypasses
        # `#set_range`'s guard. A `maximum` below `minimum` collapses the range to
        # `minimum`, matching Qt's `setRange`.
        @maximum = @minimum if @maximum < @minimum

        # `value` (domain units) takes precedence over `percent`; default to the
        # minimum (empty bar).
        if value
          self.value = value
        elsif percent
          self.percent = percent
        else
          @value = @minimum
        end

        if @keys
          handle Crysterm::Event::KeyPress
        end

        if @mouse
          # Click (or drag) to set the progress from the pointer position along
          # the bar. Uses `Event::Mouse`, not `Event::Click`, since it carries
          # cursor coordinates.
          on(Crysterm::Event::Mouse) do |e|
            next unless e.action.down?

            # A vertical bar fills bottom-up, so invert the axis: a click near the
            # top reads as full, near the bottom as empty.
            pos, span = pointer_offset e, invert: true
            next if span <= 0

            self.percent = (pos * 100 // span).clamp(0, 100)
            e.accept
          end
        end
      end

      # Size of the value range (`maximum - minimum`), never negative.
      #
      # ProgressBar is intentionally *not* built on `Mixin::RangedValue` — its
      # `complete:`-gated `Event::Completed` can't be expressed through that
      # mixin's `#value=`/`#set_range`. This must stay byte-identical to
      # `RangedValue(Int32)#value_span`'s Int32 branch; update the two in lockstep.
      private def span : Int32
        # Widen the subtraction: a range wider than `Int32::MAX` would overflow.
        (@maximum.to_i64 - @minimum).clamp(0_i64, Int32::MAX.to_i64).to_i
      end

      # Current fill as a 0..100 percentage, derived from `#value`'s position in
      # the range. An empty range (`maximum == minimum`) reads as 0. `#percent=`
      # is its inverse.
      def percent : Int32
        s = span
        return 0 if s == 0
        ((@value - @minimum) * 100.0 / s).round.to_i.clamp(0, 100)
      end

      # Sets the fill from a 0..100 percentage by mapping it back onto the range
      # (the inverse of `#percent`).
      def percent=(percent : Int32) : Int32
        # Coerce to float before multiplying: `percent * span` as Int32 × Int32
        # overflows for a range whose `span` exceeds ~21M (at percent=100).
        self.value = @minimum + (percent.clamp(0, 100).to_f * span / 100.0).round.to_i
        percent
      end

      # Current value, clamped to `[minimum, maximum]` (Qt `QProgressBar#value`).
      def value : Int32
        @value
      end

      # Sets the value, clamping it into range. Emits `Event::ValueChanged` when it
      # actually changes, and `Event::Completed` upon reaching `#maximum`.
      def value=(v : Int32) : Int32
        set_value v, complete: true
      end

      # Assigns the value (clamped), emitting `Event::ValueChanged` on a real
      # change and — when *complete* — `Event::Completed` upon reaching `#maximum`.
      protected def set_value(v : Int32, complete : Bool) : Int32
        v = v.clamp(@minimum, @maximum)
        return v if v == @value
        @value = v
        emit Crysterm::Event::ValueChanged, @value
        emit Crysterm::Event::Completed if complete && @value == @maximum && span > 0
        request_render
        @value
      end

      # Cached indicator text and the `{value, minimum, maximum, format}` it was
      # built for; `#render` calls `#formatted_text` every frame when
      # `#text_visible?`. `#percent` derives from the range, so the key covers it.
      @text_cache : String?
      @text_cache_key : Tuple(Int32, Int32, Int32, String)?

      # Builds the textual indicator from `#format` (memoized).
      private def formatted_text : String
        key = {@value, @minimum, @maximum, format}
        if @text_cache_key != key || (cached = @text_cache).nil?
          @text_cache_key = key
          @text_cache = cached = format_range_text format, percent.to_s, @value.to_s, @maximum.to_s, @minimum.to_s
        end
        cached
      end

      def render
        with_inner_coords do |xi, xl, yi, yl|
          pct = percent
          # Filled sub-region (rest of interior stays unfilled). Kept separate so
          # `xi`/`xl`/`yi`/`yl` remain the full interior for the overlay below.
          fill_xl = xl
          fill_yi = yi
          if @orientation.horizontal?
            fill_xl = xi + ((xl - xi) * (pct / 100)).to_i
          else
            fill_yi = yi + ((yl - yi) - (((yl - yi) * (pct / 100)).to_i))
          end

          # NOTE Invert fg/bg so the filled value renders using the foreground
          # color: visible even when style.indicator isn't specifically defined.
          ind = style.indicator
          default_attr = style_to_attr ind, ind.bg, ind.fg

          # TODO Is this approach with using drawing routines valid, or it would be
          # better that we do this in-memory only here?
          window.fill_region default_attr, style.percent_char, xi, fill_xl, fill_yi, yl

          # Text to overlay: the Qt-style indicator when enabled, otherwise any
          # pre-parsed content (via `#pcontent`).
          if text_visible?
            draw_overlay_text formatted_text
          elsif !(pc = pcontent).empty?
            # Overlay on the stable top interior row (`yi`), not `fill_yi` — for a
            # vertical bar that is the moving top edge of the fill, so the label
            # would slide with the value.
            draw_text_run yi, xi, pc, xl
          end
        end
      end

      # Draws `text` centered over the whole inner region, so the indicator stays
      # readable regardless of fill amount.
      private def draw_overlay_text(text : String) : Nil
        return if text.empty?
        with_inner_coords do |xi, xl, yi, yl|
          inner_w = xl - xi
          inner_h = yl - yi
          return if inner_w <= 0 || inner_h <= 0
          cy = yi + (inner_h - 1) // 2
          draw_centered_text cy, xi, xl, text
        end
      end

      def reset
        emit Crysterm::Event::Reset
        @value = @minimum
        emit Crysterm::Event::ValueChanged, @value
        request_render
      end

      def on_keypress(e)
        k = e.key
        ch = e.char
        # Keys don't conflict, so support both regardless of orientation.
        if k == Tput::Key::Left || k == Tput::Key::Down || ch == 'h' || ch == 'j'
          progress -@single_step
        elsif k == Tput::Key::Right || k == Tput::Key::Up || ch == 'l' || ch == 'k'
          progress @single_step
        end
      end
    end
  end
end
