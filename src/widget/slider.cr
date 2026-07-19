require "./abstract_slider"
require "../mixin/track_geometry"

module Crysterm
  class Widget
    # Slider element, modeled after Qt's `QSlider`.
    #
    # Lets the user pick an integer `#value` within `[#minimum, #maximum]` by
    # dragging/clicking a handle along a track, or with the keyboard (arrows step
    # by `#step`, Page Up/Down by `#page_step`, Home/End jump to the bounds). It
    # emits `Event::ValueChanged` whenever the value changes.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Slider screenshot](../../tests/widget/slider/slider.5s.apng)
    # <!-- /widget-examples:capture -->
    class Slider < AbstractSlider
      include Mixin::TrackGeometry

      # Where tick marks are drawn relative to the groove (Qt's
      # `QSlider::TickPosition`). `Above`/`Below` are the cross-axis edges of the
      # widget (top/bottom for a horizontal slider, left/right for a vertical
      # one). Ticks need a free edge row/column, so give the slider `height >= 2`
      # (horizontal) / `width >= 2` (vertical) for them to show clearly.
      enum TickPosition
        None
        Above
        Below
        Both
      end

      property orientation : Tput::Orientation = :horizontal

      # Whether the low end of the range is drawn at the far end of the track
      # (Qt's `QSlider#invertedAppearance`). Unset, a horizontal slider runs
      # left→right and a vertical one bottom→top (Qt's defaults); set, each is
      # mirrored. Handle, ticks and click/drag mapping all follow it.
      property? inverted_appearance : Bool = false

      # Whether the current value is drawn centered over the track.
      property? text_visible : Bool = false

      # Glyph used for the draggable handle and the track. Unset (`nil`)
      # resolves the CSS `glyph` on the matching sub-control (`Slider::handle`
      # — an alias of `::indicator` — and `::groove`/`track`), then the
      # `Glyphs` registry at the effective tier; assigning a `Char` pins it.
      setter handle_char : Char? = nil
      setter track_char : Char? = nil

      # :ditto:
      def handle_char : Char
        @handle_char || glyph(Glyphs::Role::SliderHandle, style.raw_sub_style("indicator"))
      end

      # :ditto:
      def track_char : Char
        @track_char || glyph(Glyphs::Role::SliderTrack, style.raw_sub_style("track"))
      end

      # Tick-mark placement and spacing (Qt's `setTickPosition`/`setTickInterval`).
      property tick_position : TickPosition = :none

      # Value-space distance between ticks. `0` means "auto": use `#page_step`
      # (falling back to `#step`).
      property tick_interval : Int32 = 0

      # Glyph used for a tick mark. Unset (`nil`) resolves from the `Glyphs`
      # registry at the effective tier.
      setter tick_char : Char? = nil

      # :ditto:
      def tick_char : Char
        @tick_char || glyph(Glyphs::Role::SliderTick)
      end

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @page_step = 10,
        @orientation = @orientation,
        @inverted_appearance = false,
        @text_visible = false,
        @handle_char = nil,
        @track_char = nil,
        @tick_position = TickPosition::None,
        @tick_interval = 0,
        @tick_char = nil,
        **input,
      )
        super **{keys: true}.merge(input)

        # Never store an inverted range; it would leave `#value` stuck after `clamp`.
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress

        # Click or drag along the track to move the handle to the pointer: a
        # press sets the value, and held-button motion events keep updating it.
        # A free move (no button) is ignored.
        on(Crysterm::Event::Mouse) do |e|
          # Wheel nudges the value by one step (up = increase).
          next if ranged_wheel e

          # Commit an untracked drag on release (no-op while `#tracking?`).
          if e.action.up?
            e.accept if commit_slider_position
            next
          end

          next unless e.action.down? || (e.action.move? && !e.button.none?)
          # A vertical slider runs bottom (min) to top (max), hence `invert`;
          # `#inverted_appearance?` flips that (and, below, the horizontal axis,
          # which `#pointer_offset` never inverts).
          pos, span_px = pointer_offset e, invert: !inverted_appearance?
          next if span_px <= 0
          pos = span_px - pos if @orientation.horizontal? && inverted_appearance?
          # Through `#slider_position=`, not `#value=`, so an untracked slider
          # moves only its handle until release.
          self.slider_position = value_at pos, span_px
          e.accept
        end
      end

      # Cached value string; `#render` draws it every frame when `#text_visible?`.
      @value_text : String = ""

      # Returns `@value.to_s`, rebuilding only when the value changed.
      private def value_text : String
        @value_text = @value.to_s if value_text_stale?
        @value_text
      end

      # Handle offset (in cells) from the low end of a track `avail` cells long.
      # Follows `#slider_position`, not `#value`, so an untracked drag still
      # moves the drawn handle before it commits.
      private def handle_offset(avail : Int32) : Int32
        return 0 if value_span == 0 || avail <= 0
        value_to_cell(slider_position.to_i64, avail).clamp(0, avail)
      end

      # Maps a low-end cell offset *c* onto the main-axis cell in `lo...hi`.
      # A horizontal slider runs low→high left→right, a vertical one bottom→top
      # (Qt's defaults); `#inverted_appearance?` mirrors whichever it is.
      private def track_cell(c : Int32, lo : Int32, hi : Int32) : Int32
        if @orientation.horizontal? ^ inverted_appearance?
          lo + c
        else
          (hi - 1) - c
        end
      end

      # Main-axis cell of the handle on the track spanning `lo...hi`.
      private def handle_cell(lo : Int32, hi : Int32) : Int32
        track_cell handle_offset(hi - lo - 1), lo, hi
      end

      # Effective value-space spacing between ticks.
      private def effective_tick_interval : Int32
        return @tick_interval if @tick_interval > 0
        @page_step > 0 ? @page_step : Math.max(@step, 1)
      end

      # Reused scratch for the (at most two) tick-mark edge rows/columns, so
      # `#draw_ticks` doesn't allocate every frame while ticks are enabled. Only
      # one branch runs per call, so sharing it across both is safe.
      @tick_edges = [] of Int32

      # Yields each tick's cell offset (`0..avail`) from the low-value end of a
      # track `avail` cells long. Bounded by the track length: iterating value
      # space instead would hang on a large range, and overflow the `tv` Int32
      # accumulator when `@maximum` sits within `interval` of `Int32::MAX`.
      private def each_tick_cell(avail : Int32, interval : Int32, & : Int32 ->) : Nil
        return if avail <= 0 || interval <= 0 || value_span <= 0
        if value_span // interval > avail
          # Ticks are denser than cells: at most one distinct mark per cell, so
          # walk cells instead of value space.
          (0..avail).each { |c| yield c }
        else
          tv = @minimum
          while tv <= @maximum
            yield value_to_cell(tv.to_i64, avail)
            break if tv > @maximum - interval # guard the `tv += interval` overflow
            tv += interval
          end
        end
      end

      # Draws tick marks along the requested edges of the groove. Skips the
      # handle cell so the handle stays visible even on a one-row/column slider.
      private def draw_ticks(xi, xl, yi, yl)
        return if value_span == 0
        interval = effective_tick_interval
        attr = style_to_attr style
        edges = @tick_edges
        # Hoisted out of the per-tick loops: registry resolution walks to the window.
        tick_ch = tick_char

        if @orientation.horizontal?
          avail = xl - xi - 1
          return if avail <= 0
          edges.clear
          edges << yi if @tick_position.above? || @tick_position.both?
          edges << (yl - 1) if @tick_position.below? || @tick_position.both?
          hx = handle_cell(xi, xl)
          each_tick_cell(avail, interval) do |c|
            tx = track_cell(c, xi, xl)
            next if tx == hx
            edges.each { |ty| window.fill_region attr, tick_ch, tx, tx + 1, ty, ty + 1 }
          end
        else
          avail = yl - yi - 1
          return if avail <= 0
          edges.clear
          edges << xi if @tick_position.above? || @tick_position.both?
          edges << (xl - 1) if @tick_position.below? || @tick_position.both?
          hy = handle_cell(yi, yl)
          each_tick_cell(avail, interval) do |c|
            ty = track_cell(c, yi, yl)
            next if ty == hy
            edges.each { |cx| window.fill_region attr, tick_ch, cx, cx + 1, ty, ty + 1 }
          end
        end
      end

      def render
        # Must paint into the *content* region (border AND padding inset), not the
        # border-only interior: `#pointer_offset` maps clicks through insets that
        # include padding, so anything else makes the drawn handle and the
        # click-mapped value disagree on a padded slider.
        with_content_coords do |xi, xl, yi, yl|
          track_attr = style_to_attr style
          window.fill_region track_attr, track_char, xi, xl, yi, yl

          handle_attr = style_to_attr style.indicator
          # The handle is a contiguous run across the cross axis, so it goes
          # through the batched `fill_region`, not a per-cell loop.
          if @orientation.horizontal?
            hx = handle_cell(xi, xl)
            window.fill_region handle_attr, handle_char, hx, hx + 1, yi, yl
          else
            hy = handle_cell(yi, yl)
            window.fill_region handle_attr, handle_char, xi, xl, hy, hy + 1
          end

          draw_ticks(xi, xl, yi, yl) unless @tick_position.none?

          if text_visible?
            txt = value_text
            cy = yi + (yl - yi - 1) // 2
            # Stamp the track attr too, not just the glyph: the center row also
            # carries the handle cell, so a digit landing there would otherwise
            # wear the handle's indicator attr.
            draw_centered_text cy, xi, xl, txt, track_attr
          end
        end
      end
    end
  end
end
