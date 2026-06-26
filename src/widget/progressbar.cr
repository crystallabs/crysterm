module Crysterm
  class Widget
    # Progress bar element, modeled after Qt's `QProgressBar`.
    #
    # The authoritative state is `#value`, an integer within the inclusive range
    # `[#minimum, #maximum]`. The visually filled portion (`#filled`, a 0..100
    # percentage) is derived from where `value` sits in that range, so callers may
    # drive the bar either in domain units (`bar.value = 42`, range 0..200) or in
    # plain percentages (`bar.filled = 50`) — both stay consistent.
    #
    # <!-- widget-examples:capture v1 -->
    # ![ProgressBar screenshot](../../examples/widget/progressbar/progressbar-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class ProgressBar < Input
      # Lower/upper bounds of the value range (inclusive), like Qt's
      # `minimum`/`maximum`. With the defaults (0..100) a value equals its
      # percentage. Setting `maximum == minimum` yields a "busy"/empty bar.
      property minimum : Int32 = 0
      property maximum : Int32 = 100

      # Amount a single key press (or default `#progress`) moves the value by,
      # in domain units. Mirrors Qt's `QAbstractSlider#singleStep`.
      property step : Int32 = 5

      property orientation : Tput::Orientation = :horizontal

      # Whether to draw the textual indicator (see `#text_format`) over the bar,
      # like Qt's `QProgressBar#textVisible`.
      property? show_text : Bool = false

      # Template for the text drawn when `#show_text?`. Recognized placeholders,
      # matching Qt's `QProgressBar#format`: `%p` percentage, `%v` current value,
      # `%m` maximum, `%M` minimum.
      property text_format : String = "%p%"

      # XXX Change this to enabled? later.
      property? keys : Bool = true
      property? mouse : Bool = false

      @value : Int32 = 0

      def initialize(
        filled : Int32? = nil,
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 5,
        @show_text = false,
        @text_format = "%p%",
        @keys = true,
        @mouse = false,
        @orientation = @orientation,
        **input,
      )
        super **input

        # `value` (domain units) takes precedence; otherwise honor `filled`
        # (percentage). Default to the minimum (empty bar).
        if value
          self.value = value
        elsif filled
          self.filled = filled
        else
          @value = @minimum
        end

        if @keys
          handle Crysterm::Event::KeyPress
        end

        if @mouse
          # Click (or drag) to set the progress from the pointer position along
          # the bar, mirroring Blessed. Uses `Event::Mouse` (not the bare
          # `Event::Click`) because it carries the cursor coordinates.
          on(Crysterm::Event::Mouse) do |e|
            next unless e.action.down?

            if @orientation.horizontal?
              pos = e.x - aleft - ileft
              span = awidth - iwidth
            else
              pos = e.y - atop - itop
              span = aheight - iheight
            end
            next if span <= 0

            self.filled = (pos * 100 // span).clamp(0, 100)
            e.accept
          end
        end
      end

      # Size of the value range (`maximum - minimum`), never negative.
      private def span : Int32
        Math.max(0, @maximum - @minimum)
      end

      # Current fill as a 0..100 percentage, derived from `#value`'s position in
      # the range. An empty range (`maximum == minimum`) reads as 0.
      def filled : Int32
        s = span
        return 0 if s == 0
        ((@value - @minimum) * 100.0 / s).round.to_i.clamp(0, 100)
      end

      # Sets the fill from a 0..100 percentage by mapping it back onto the range.
      def filled=(percent : Int32) : Int32
        self.value = @minimum + (percent.clamp(0, 100) * span / 100.0).round.to_i
        percent
      end

      # Current value, clamped to `[minimum, maximum]` (Qt `QProgressBar#value`).
      def value : Int32
        @value
      end

      # Sets the value, clamping it into range. Emits `Event::ValueChange` when it
      # actually changes, and `Event::Complete` upon reaching `#maximum`.
      def value=(v : Int32) : Int32
        v = v.clamp(@minimum, @maximum)
        return v if v == @value
        @value = v
        emit Crysterm::Event::ValueChange, @value
        emit Crysterm::Event::Complete if @value == @maximum && span > 0
        request_render
        @value
      end

      # Builds the textual indicator from `#text_format`.
      private def formatted_text : String
        text_format
          .gsub("%p", filled.to_s)
          .gsub("%v", @value.to_s)
          .gsub("%m", @maximum.to_s)
          .gsub("%M", @minimum.to_s)
      end

      def render
        with_inner_coords do |xi, xl, yi, yl|
          pct = filled
          if @orientation.horizontal?
            xl = xi + ((xl - xi) * (pct / 100)).to_i
          else
            yi = yi + ((yl - yi) - (((yl - yi) * (pct / 100)).to_i))
          end

          # NOTE We invert fg and bg here, so that progressbar's filled value would be
          # rendered using foreground color. This is different than blessed, and:
          # 1) Arguably more correct as far as logic goes
          # 2) And also allows the widget to show filled value in a way which is visible
          #    even if style.indicator is not specifically defined
          ind = style.indicator
          default_attr = sattr ind, ind.bg, ind.fg

          # TODO Is this approach with using drawing routines valid, or it would be
          # better that we do this in-memory only here?
          screen.fill_region default_attr, style.percent_char, xi, xl, yi, yl

          # Determine the text to overlay: the Qt-style indicator when enabled,
          # otherwise any pre-parsed content (materialized via `#pcontent`).
          if show_text?
            draw_overlay_text formatted_text
          elsif !(pc = pcontent).empty?
            screen.lines[yi]?.try do |line|
              pc.each_char_with_index do |c, i|
                line[xi + i]?.try do |cell|
                  cell.char = c
                end
              end
              line.dirty = true
            end
          end
        end
      end

      # Draws `text` centered over the whole inner region (used for `show_text?`),
      # so the indicator stays readable regardless of how much of the bar is
      # filled.
      private def draw_overlay_text(text : String) : Nil
        return if text.empty?
        with_inner_coords do |xi, xl, yi, yl|
          inner_w = xl - xi
          inner_h = yl - yi
          return if inner_w <= 0 || inner_h <= 0
          cy = yi + (inner_h - 1) // 2
          cx = xi + Math.max(0, (inner_w - text.size) // 2)
          screen.lines[cy]?.try do |line|
            text.each_char_with_index do |c, i|
              break if cx + i >= xl
              line[cx + i]?.try do |cell|
                cell.char = c
              end
            end
            line.dirty = true
          end
        end
      end

      # Advances the value by `delta` domain units (negative to go back),
      # clamping into range.
      def progress(delta : Int32)
        self.value = @value + delta
      end

      def reset
        emit Crysterm::Event::Reset
        @value = @minimum
        emit Crysterm::Event::ValueChange, @value
        request_render
      end

      def on_keypress(e)
        k = e.key
        ch = e.char
        # Since the keys aren't conflicting, support both regardless of
        # orientation. `#progress` routes through `#value=`, which repaints on
        # an actual change.
        if k == Tput::Key::Left || k == Tput::Key::Down || ch == 'h' || ch == 'j'
          progress -@step
        elsif k == Tput::Key::Right || k == Tput::Key::Up || ch == 'l' || ch == 'k'
          progress @step
        end
      end
    end
  end
end
