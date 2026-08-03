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

      # `#range=`/`#span`: ProgressBar can't include the rest of
      # `Mixin::RangedValue` — its `complete:`-gated `Event::Completed` doesn't
      # fit that mixin's single clamp-and-emit `#value=` — but these two are
      # pure fragments written only against `#minimum`/`#maximum`/`#set_range`,
      # so it includes the narrower `RangeSpan(Int32)` for them directly
      # (dispatch through `#set_range` below still runs ProgressBar's own).
      include Mixin::RangeSpan(Int32)

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

      # `#range=` (the `Range`-based `#set_range` sugar, Qt's `setRange`) comes
      # from `Mixin::RangeSpan(Int32)`, included above.

      # Amount a single key press moves the value by, in domain units. Qt's
      # `QAbstractSlider#singleStep`.
      property single_step : Int32 = 5

      property orientation : Tput::Orientation = :horizontal

      # Whether to draw the textual indicator (see `#format`) over the bar,
      # like Qt's `QProgressBar#textVisible`.
      getter? text_visible : Bool = false

      # Assigns `#text_visible?` and schedules a repaint: `#render` reads it
      # directly (no content cache to key on), so a bare `property` setter's
      # change would only become visible on some later, unrelated frame.
      repaint_property text_visible, Bool

      # Template for the text drawn when `#text_visible?`. Recognized placeholders,
      # matching Qt's `QProgressBar#format`: `%p` percentage, `%v` current value,
      # `%m` maximum, `%M` minimum.
      getter format : String = "%p%"

      # Assigns `#format` and schedules a repaint (see `#text_visible=`).
      repaint_property format, String

      # Separate gates for keyboard vs. mouse interaction (an interactive bar can
      # be driven by either). Kept as `keys`/`mouse` rather than folded into one
      # `enabled?`: they toggle independently, and `enabled?` already carries Qt's
      # distinct widget enabled/disabled meaning.
      property? keys : Bool = true
      property? mouse : Bool = false

      @value : Int32 = 0

      def initialize(
        percent : Int32? = nil,
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        single_step : Int32? = nil,
        step : Int32? = nil,
        @text_visible = false,
        @format = "%p%",
        @keys = true,
        @mouse = false,
        @orientation = @orientation,
        **input,
      )
        # `single_step:` is the blessed Qt-parity spelling; `step:` is accepted
        # as a compatibility alias for consistency with the other ranged
        # widgets, `single_step:` winning when both are given.
        @single_step = single_step || step || 5

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

      # `#span` (size of the value range, never negative) comes from
      # `Mixin::RangeSpan(Int32)`, included above.

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

      # `style_to_attr` memo for the per-frame fill attr (`style.indicator`):
      # the bar redraws every frame with an unchanged style, so the derivation
      # is skipped until the slot's style is mutated or swapped. Caches the
      # plain (unswapped) form; `#render` swaps the packed fg/bg fields itself.
      @indicator_attr_memo = Style::AttrMemo.new

      # Builds the textual indicator from `#format` (memoized).
      private def formatted_text : String
        key = {@value, @minimum, @maximum, format}
        if @text_cache_key != key || (cached = @text_cache).nil?
          @text_cache_key = key
          @text_cache = cached = format_range_text format, percent.to_s, @value.to_s, @maximum.to_s, @minimum.to_s
        end
        cached
      end

      def render(with_children = true)
        with_inner_coords(with_children) do |xi, xl, yi, yl|
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
          # Swapping the packed color fields of the memoized plain attr packs
          # the identical value as `style_to_attr(ind, ind.bg, ind.fg)`: both
          # slots carry `pack_color(<color> || -1)`, and the both-`nil`
          # fallback is symmetric.
          ind = style.indicator
          plain = @indicator_attr_memo.fetch(ind)
          default_attr = Attr.pack(Attr.flags(plain), Attr.bg(plain), Attr.fg(plain))

          # Filling via `window.fill_region` is the standard bar/meter draw path,
          # shared with `Slider` / `ScrollBar` / `Dial` / `Gradient`: it writes
          # straight into the window cell buffer the frame diff already tracks, so
          # there is no separate in-memory step to add.
          # Fill glyph: registry `ProgressFill` (a space, showing as a solid bar
          # via the fg/bg inversion above), overridable per-widget with
          # `ProgressBar::indicator { glyph: "▓" }`.
          window.fill_region default_attr, glyph(Glyphs::Role::ProgressFill, ind), xi, fill_xl, fill_yi, yl

          # Text to overlay: the Qt-style indicator when enabled, otherwise any
          # pre-parsed content (via `#pcontent`).
          if text_visible?
            draw_overlay_text xi, xl, yi, yl, formatted_text
          elsif !(pc = pcontent).empty?
            # Overlay on the stable top interior row (`yi`), not `fill_yi` — for a
            # vertical bar that is the moving top edge of the fill, so the label
            # would slide with the value.
            draw_text_run yi, xi, pc, xl
          end
        end
      end

      # Draws `text` centered over the whole inner region (passed in from
      # `#render`'s own `with_inner_coords` block), so the indicator stays
      # readable regardless of fill amount. Takes the coords as arguments
      # rather than re-entering `with_inner_coords`: that helper re-runs
      # `base_render`, whose interior repaint would erase the fill drawn just
      # before the overlay.
      private def draw_overlay_text(xi : Int32, xl : Int32, yi : Int32, yl : Int32, text : String) : Nil
        return if text.empty?
        inner_w = xl - xi
        inner_h = yl - yi
        return if inner_w <= 0 || inner_h <= 0
        cy = yi + (inner_h - 1) // 2
        draw_centered_text cy, xi, xl, text
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
          self.value = @value - @single_step
          e.accept
        elsif k == Tput::Key::Right || k == Tput::Key::Up || ch == 'l' || ch == 'k'
          self.value = @value + @single_step
          e.accept
        end
      end
    end
  end
end
