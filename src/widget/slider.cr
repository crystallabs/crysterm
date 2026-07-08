require "./abstract_slider"
require "../mixin/track_geometry"

module Crysterm
  class Widget
    # Slider element, modeled after Qt's `QSlider`.
    #
    # Lets the user pick an integer `#value` within `[#minimum, #maximum]` by
    # dragging/clicking a handle along a track, or with the keyboard (arrows step
    # by `#step`, Page Up/Down by `#page_step`, Home/End jump to the bounds). It
    # emits `Event::ValueChange` whenever the value changes.
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

      # Whether the current value is drawn centered over the track.
      property? show_value : Bool = false

      # Glyph used for the draggable handle and the track.
      property handle_char : Char = '█'
      property track_char : Char = '─'

      # Tick-mark placement and spacing (Qt's `setTickPosition`/`setTickInterval`).
      property tick_position : TickPosition = :none

      # Value-space distance between ticks. `0` means "auto": use `#page_step`
      # (falling back to `#step`).
      property tick_interval : Int32 = 0

      # Glyph used for a tick mark.
      property tick_char : Char = '·'

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @page_step = 10,
        @orientation = @orientation,
        @show_value = false,
        @handle_char = '█',
        @track_char = '─',
        @tick_position = TickPosition::None,
        @tick_interval = 0,
        @tick_char = '·',
        **input,
      )
        super **input

        # Guarded range+value init: never store an inverted range (which would
        # leave `#value` stuck after `clamp`). Shared with `Dial`/`ScrollBar`.
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress

        # Click or drag along the track to move the handle to the pointer: a
        # press sets the value, and held-button motion events keep updating it.
        # A free move (no button) is ignored.
        on(Crysterm::Event::Mouse) do |e|
          # Wheel nudges the value by one step (up = increase).
          next if ranged_wheel e

          next unless e.action.down? || (e.action.move? && !e.button.none?)
          # Vertical sliders run bottom (min) to top (max), hence `invert`.
          pos, span_px = pointer_offset e, invert: true
          next if span_px <= 0
          self.value = value_at pos, span_px
          e.accept
        end
      end

      # Cached value string. `#render` draws it every frame when `#show_value?`;
      # `@value.to_s` only needs to rerun when the value changes (see
      # `AbstractSlider#value_text_stale?`).
      @value_text : String = ""

      # Returns `@value.to_s`, rebuilding only when the value changed.
      private def value_text : String
        @value_text = @value.to_s if value_text_stale?
        @value_text
      end

      # Handle offset (in cells) from the low end of a track `avail` cells long.
      private def handle_offset(avail : Int32) : Int32
        return 0 if value_span == 0 || avail <= 0
        ((@value - @minimum).to_f * avail / value_span).round.to_i.clamp(0, avail)
      end

      # Effective value-space spacing between ticks.
      private def effective_tick_interval : Int32
        return @tick_interval if @tick_interval > 0
        @page_step > 0 ? @page_step : Math.max(@step, 1)
      end

      # Reused scratch for the (at most two) tick-mark edge rows/columns, so
      # `#draw_ticks` doesn't allocate a fresh `[] of Int32` every frame while
      # ticks are enabled. Only one branch runs per call; `.clear` + refill makes
      # it safe to share across the horizontal/vertical paths.
      @tick_edges = [] of Int32

      # Draws tick marks along the requested edges of the groove. Skips the
      # handle cell so the handle stays visible even on a one-row/column slider.
      private def draw_ticks(xi, xl, yi, yl)
        return if value_span == 0
        interval = effective_tick_interval
        attr = sattr style
        edges = @tick_edges

        if @orientation.horizontal?
          avail = xl - xi - 1
          return if avail <= 0
          edges.clear
          edges << yi if @tick_position.above? || @tick_position.both?
          edges << (yl - 1) if @tick_position.below? || @tick_position.both?
          hx = xi + handle_offset(avail)
          tv = @minimum
          while tv <= @maximum
            tx = xi + ((tv - @minimum).to_f * avail / value_span).round.to_i
            unless tx == hx
              edges.each { |ty| window.fill_region attr, @tick_char, tx, tx + 1, ty, ty + 1 }
            end
            tv += interval
          end
        else
          avail = yl - yi - 1
          return if avail <= 0
          edges.clear
          edges << xi if @tick_position.above? || @tick_position.both?
          edges << (xl - 1) if @tick_position.below? || @tick_position.both?
          hy = (yl - 1) - handle_offset(avail)
          tv = @minimum
          while tv <= @maximum
            ty = (yl - 1) - ((tv - @minimum).to_f * avail / value_span).round.to_i
            unless ty == hy
              edges.each { |cx| window.fill_region attr, @tick_char, cx, cx + 1, ty, ty + 1 }
            end
            tv += interval
          end
        end
      end

      def render
        with_inner_coords do |xi, xl, yi, yl|
          track_attr = sattr style
          window.fill_region track_attr, @track_char, xi, xl, yi, yl

          handle_attr = sattr style.indicator
          # The handle is a contiguous 1-cell-wide run across the cross axis, so
          # it goes through `fill_region` (batched, skips unchanged cells) like
          # the track above — not a per-cell loop.
          if @orientation.horizontal?
            hx = xi + handle_offset(xl - xi - 1)
            window.fill_region handle_attr, @handle_char, hx, hx + 1, yi, yl
          else
            hy = (yl - 1) - handle_offset(yl - yi - 1)
            window.fill_region handle_attr, @handle_char, xi, xl, hy, hy + 1
          end

          draw_ticks(xi, xl, yi, yl) unless @tick_position.none?

          if show_value?
            txt = value_text
            cy = yi + (yl - yi - 1) // 2
            # Stamp the track attr too, not just the glyph: the center row also
            # carries the handle cell, and writing only the char left a digit on
            # the handle wearing its (indicator/reverse) attr.
            draw_centered_text cy, xi, xl, txt, track_attr
          end
        end
      end
    end
  end
end
