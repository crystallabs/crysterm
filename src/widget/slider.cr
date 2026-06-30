require "./abstract_slider"

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

      # A slider draws a fixed-size track; it should not shrink to its (empty)
      # content the way an `Input` does by default.
      @resizable = false

      # Amount Page Up/Down move the value by (Qt `pageStep`).
      property page_step : Int32 = 10

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

        @value = (value || @minimum).clamp(@minimum, @maximum)

        handle Crysterm::Event::KeyPress

        # Click *or drag* along the track to move the handle to the pointer. A
        # press sets the value; while the button stays held, motion events (which
        # still report the held button) keep updating it, so the handle follows
        # the drag. A free move (no button) is ignored.
        on(Crysterm::Event::Mouse) do |e|
          # Wheel nudges the value by one step (up = increase).
          next if ranged_wheel e

          next unless e.action.down? || (e.action.move? && !e.button.none?)
          if @orientation.horizontal?
            pos = e.x - aleft - ileft
            span_px = awidth - iwidth - 1
          else
            # Vertical sliders run bottom (min) to top (max).
            pos = (aheight - iheight - 1) - (e.y - atop - itop)
            span_px = aheight - iheight - 1
          end
          next if span_px <= 0
          self.value = @minimum + (pos * value_span / span_px.to_f).round.to_i
          e.accept
        end
      end

      # Handle offset (in cells) from the low end of a track `avail` cells long.
      private def handle_offset(avail : Int32) : Int32
        return 0 if value_span == 0 || avail <= 0
        ((@value - @minimum) * avail / value_span.to_f).round.to_i.clamp(0, avail)
      end

      # Effective value-space spacing between ticks.
      private def effective_tick_interval : Int32
        return @tick_interval if @tick_interval > 0
        @page_step > 0 ? @page_step : Math.max(@step, 1)
      end

      # Draws tick marks along the requested edges of the groove. Skips the
      # handle cell so the handle stays visible even on a one-row/column slider.
      private def draw_ticks(xi, xl, yi, yl)
        return if value_span == 0
        interval = effective_tick_interval
        attr = sattr style

        if @orientation.horizontal?
          avail = xl - xi - 1
          return if avail <= 0
          rows = [] of Int32
          rows << yi if @tick_position.above? || @tick_position.both?
          rows << (yl - 1) if @tick_position.below? || @tick_position.both?
          hx = xi + handle_offset(avail)
          tv = @minimum
          while tv <= @maximum
            tx = xi + ((tv - @minimum) * avail / value_span.to_f).round.to_i
            unless tx == hx
              rows.each do |ty|
                window.lines[ty]?.try do |line|
                  line[tx]?.try do |cell|
                    cell.char = @tick_char
                    cell.attr = attr
                  end
                  line.dirty = true
                end
              end
            end
            tv += interval
          end
        else
          avail = yl - yi - 1
          return if avail <= 0
          cols = [] of Int32
          cols << xi if @tick_position.above? || @tick_position.both?
          cols << (xl - 1) if @tick_position.below? || @tick_position.both?
          hy = (yl - 1) - handle_offset(avail)
          tv = @minimum
          while tv <= @maximum
            ty = (yl - 1) - ((tv - @minimum) * avail / value_span.to_f).round.to_i
            unless ty == hy
              window.lines[ty]?.try do |line|
                cols.each do |cx|
                  line[cx]?.try do |cell|
                    cell.char = @tick_char
                    cell.attr = attr
                  end
                end
                line.dirty = true
              end
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
          if @orientation.horizontal?
            hx = xi + handle_offset(xl - xi - 1)
            (yi...yl).each do |y|
              window.lines[y]?.try do |line|
                line[hx]?.try do |cell|
                  cell.char = @handle_char
                  cell.attr = handle_attr
                end
                line.dirty = true
              end
            end
          else
            hy = (yl - 1) - handle_offset(yl - yi - 1)
            window.lines[hy]?.try do |line|
              (xi...xl).each do |x|
                line[x]?.try do |cell|
                  cell.char = @handle_char
                  cell.attr = handle_attr
                end
              end
              line.dirty = true
            end
          end

          draw_ticks(xi, xl, yi, yl) unless @tick_position.none?

          if show_value?
            txt = @value.to_s
            cx = xi + Math.max(0, (xl - xi - txt.size) // 2)
            cy = yi + (yl - yi - 1) // 2
            # Set the attr too, not just the glyph: the value text rides over the
            # center row, which also carries the handle cell. Writing only the
            # char left a digit landing on the handle wearing the handle's
            # (indicator/reverse) attr, so the readout came out unevenly styled.
            # Stamp the track attr so every digit reads consistently.
            draw_text_run cy, cx, txt, xl, track_attr
          end
        end
      end

      # Arrow/Page/Home/End stepping is shared with `Dial` via
      # `Mixin::RangedValue#ranged_step_key`.
      def on_keypress(e)
        ranged_step_key e
      end
    end
  end
end
