require "./input"

module Crysterm
  class Widget
    # Slider element, modeled after Qt's `QSlider`.
    #
    # Lets the user pick an integer `#value` within `[#minimum, #maximum]` by
    # dragging/clicking a handle along a track, or with the keyboard (arrows step
    # by `#step`, Page Up/Down by `#page_step`, Home/End jump to the bounds). It
    # emits `Event::ValueChange` whenever the value changes.
    class Slider < Input
      # A slider draws a fixed-size track; it should not shrink to its (empty)
      # content the way an `Input` does by default.
      @resizable = false

      property minimum : Int32 = 0
      property maximum : Int32 = 100

      # Amount the arrow keys move the value by (Qt `singleStep`).
      property step : Int32 = 1
      # Amount Page Up/Down move the value by (Qt `pageStep`).
      property page_step : Int32 = 10

      property orientation : Tput::Orientation = :horizontal

      # Whether the current value is drawn centered over the track.
      property? show_value : Bool = false

      # Glyph used for the draggable handle and the track.
      property handle_char : Char = '█'
      property track_char : Char = '─'

      @value : Int32 = 0

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
        **input,
      )
        super **input

        @value = (value || @minimum).clamp(@minimum, @maximum)

        handle Crysterm::Event::KeyPress

        # Click (or drag) along the track to jump the handle to the pointer.
        on(Crysterm::Event::Mouse) do |e|
          next unless e.action.down?
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
          request_render
        end
      end

      private def value_span : Int32
        Math.max(0, @maximum - @minimum)
      end

      def value : Int32
        @value
      end

      def value=(v : Int32) : Int32
        v = v.clamp(@minimum, @maximum)
        return v if v == @value
        @value = v
        emit Crysterm::Event::ValueChange, @value
        request_render
        @value
      end

      def increment(by : Int32 = @step)
        self.value = @value + by
      end

      def decrement(by : Int32 = @step)
        self.value = @value - by
      end

      # Handle offset (in cells) from the low end of a track `avail` cells long.
      private def handle_offset(avail : Int32) : Int32
        return 0 if value_span == 0 || avail <= 0
        ((@value - @minimum) * avail / value_span.to_f).round.to_i.clamp(0, avail)
      end

      def render
        with_inner_coords do |xi, xl, yi, yl|
          track_attr = sattr style
          screen.fill_region track_attr, @track_char, xi, xl, yi, yl

          handle_attr = sattr style.bar
          if @orientation.horizontal?
            hx = xi + handle_offset(xl - xi - 1)
            (yi...yl).each do |y|
              screen.lines[y]?.try do |line|
                line[hx]?.try do |cell|
                  cell.char = @handle_char
                  cell.attr = handle_attr
                end
                line.dirty = true
              end
            end
          else
            hy = (yl - 1) - handle_offset(yl - yi - 1)
            screen.lines[hy]?.try do |line|
              (xi...xl).each do |x|
                line[x]?.try do |cell|
                  cell.char = @handle_char
                  cell.attr = handle_attr
                end
              end
              line.dirty = true
            end
          end

          if show_value?
            txt = @value.to_s
            cx = xi + Math.max(0, (xl - xi - txt.size) // 2)
            cy = yi + (yl - yi - 1) // 2
            screen.lines[cy]?.try do |line|
              txt.each_char_with_index do |ch, i|
                break if cx + i >= xl
                line[cx + i]?.try &.char = ch
              end
              line.dirty = true
            end
          end
        end
      end

      def on_keypress(e)
        k = e.key
        ch = e.char
        if k == Tput::Key::Left || k == Tput::Key::Down || ch == 'h' || ch == 'j'
          decrement
          e.accept
          request_render
        elsif k == Tput::Key::Right || k == Tput::Key::Up || ch == 'l' || ch == 'k'
          increment
          e.accept
          request_render
        elsif k == Tput::Key::PageDown
          decrement @page_step
          e.accept
          request_render
        elsif k == Tput::Key::PageUp
          increment @page_step
          e.accept
          request_render
        elsif k == Tput::Key::Home
          self.value = @minimum
          e.accept
          request_render
        elsif k == Tput::Key::End
          self.value = @maximum
          e.accept
          request_render
        end
      end
    end
  end
end
