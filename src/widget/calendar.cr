require "./box"

module Crysterm
  class Widget
    # Month calendar, modeled after Qt's `QCalendarWidget`.
    #
    # Shows the month containing the selected `#date` as a grid of day cells with
    # a weekday header. The selection moves with the arrow keys (Left/Right by a
    # day, Up/Down by a week), Page Up/Down change the month, Home/End jump to the
    # first/last day of the month, and a click selects a day. Emits
    # `Event::DateChange` whenever the selected date changes and `Event::Action`
    # when a day is activated (Enter or click).
    #
    # ```
    # cal = Widget::Calendar.new parent: screen, top: 0, left: 0, width: 22, height: 9,
    #   style: Style.new(border: true)
    # cal.on(Event::DateChange) { |e| status.content = e.date.to_s("%Y-%m-%d") }
    # ```
    class Calendar < Box
      WEEKDAYS = %w[Su Mo Tu We Th Fr Sa]
      MONTHS   = %w[January February March April May June July August September October November December]

      # A calendar is an interactive control: mark it keyable so the screen
      # routes key events to it when focused (e.g. as a `DateEdit` popup, or when
      # reached by Tab). Without this it would render but never receive keys.
      @keys = true

      @date : Time

      # `Time.local` is unavailable in some headless contexts; fall back to the
      # epoch so construction never raises (callers normally pass a date anyway).
      private def default_today : Time
        Time.local
      rescue
        Time.utc(2000, 1, 1)
      end

      # The selected date (at the beginning of its day).
      def date : Time
        @date
      end

      # Sets the selected date, emitting `Event::DateChange` on an actual change.
      def date=(value : Time) : Time
        v = value.at_beginning_of_day
        return @date if v == @date
        @date = v
        update_content
        emit Crysterm::Event::DateChange, @date
        request_render
        @date
      end

      private def shift_days(n : Int32) : Nil
        self.date = @date + n.days
      end

      private def shift_months(n : Int32) : Nil
        total = @date.year * 12 + (@date.month - 1) + n
        y = total // 12
        m = total % 12 + 1
        d = Math.min(@date.day, Time.days_in_month(y, m))
        self.date = Time.local(y, m, d)
      end

      # Column (0 = Sunday .. 6 = Saturday) of *t*'s weekday.
      private def sunday_column(t : Time) : Int32
        t.day_of_week.value % 7
      end

      private def update_content : Nil
        set_content build_content
      end

      # Builds the tagged month grid; the selected day is drawn inverse.
      private def build_content : String
        first = Time.local(@date.year, @date.month, 1)
        dim = Time.days_in_month(@date.year, @date.month)
        lead = sunday_column first

        String.build do |io|
          title = "#{MONTHS[@date.month - 1]} #{@date.year}"
          io << "{center}" << title << "{/center}\n"
          io << WEEKDAYS.join(' ') << '\n'

          col = 0
          lead.times do
            io << "   "
            col += 1
          end

          (1..dim).each do |d|
            cell = d.to_s.rjust 2
            if d == @date.day
              io << "{inverse}" << cell << "{/inverse}"
            else
              io << cell
            end
            col += 1
            if col == 7
              io << '\n'
              col = 0
            else
              io << ' '
            end
          end
        end
      end

      # Maps an absolute click to a day number, or `nil` if it isn't on a cell.
      private def day_at(x : Int32, y : Int32) : Int32?
        row = y - atop - itop - 2 # rows 0,1 are title + weekday header
        return nil if row < 0
        col = (x - aleft - ileft) // 3
        return nil if col < 0 || col > 6

        first = Time.local(@date.year, @date.month, 1)
        lead = sunday_column first
        cell = row * 7 + col
        d = cell - lead + 1
        (1 <= d <= Time.days_in_month(@date.year, @date.month)) ? d : nil
      rescue
        nil
      end

      def initialize(date : Time? = nil, mouse = true, **box)
        @date = (date || default_today).at_beginning_of_day
        super **box
        @parse_tags = true

        handle Crysterm::Event::KeyPress

        if mouse
          on(Crysterm::Event::Mouse) do |e|
            next unless e.action.down?
            if d = day_at(e.x, e.y)
              self.date = Time.local(@date.year, @date.month, d)
              emit Crysterm::Event::Action, @date.to_s("%Y-%m-%d")
              e.accept
              request_render
            end
          end
        end

        update_content
      end

      def on_keypress(e)
        case e.key
        when Tput::Key::Left
          shift_days -1
        when Tput::Key::Right
          shift_days 1
        when Tput::Key::Up
          shift_days -7
        when Tput::Key::Down
          shift_days 7
        when Tput::Key::PageUp
          shift_months -1
        when Tput::Key::PageDown
          shift_months 1
        when Tput::Key::Home
          self.date = Time.local(@date.year, @date.month, 1)
        when Tput::Key::End
          self.date = Time.local(@date.year, @date.month, Time.days_in_month(@date.year, @date.month))
        when Tput::Key::Enter
          emit Crysterm::Event::Action, @date.to_s("%Y-%m-%d")
        else
          return
        end
        e.accept
        request_render
      end
    end
  end
end
