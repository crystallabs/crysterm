require "./abstract_spin_box"
require "../mixin/sectioned_field"

module Crysterm
  class Widget
    # Combined date+time entry field, modeled after Qt's `QDateTimeEdit`.
    #
    # Shows `YYYY-MM-DD HH:MM:SS` with one *section* highlighted, joining the
    # behavior of `DateEdit` and `TimeEdit`: Left/Right move between the six
    # sections, Up/Down (or the mouse wheel over a section) step it — wrapping
    # within the section's own range without carrying — and a click selects the
    # section under the pointer. Emits `Event::DateChange` (carrying the `Time`)
    # on every change.
    #
    # Like Qt's default `QDateTimeEdit` (`calendarPopup == false`), it is edited
    # in place with no drop-down. The shared section machinery lives in
    # `Mixin::SectionedField`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![DateTimeEdit screenshot](../../examples/widget/date_time_edit/date_time_edit-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class DateTimeEdit < AbstractSpinBox
      include Mixin::SectionedField

      @resizable = false

      @datetime : Time
      # `@section`: 0=year 1=month 2=day 3=hour 4=minute 5=second.

      # Whether the seconds section is shown and editable.
      property? show_seconds : Bool = true

      # Re-wrap the generated setter so toggling seconds off while the seconds
      # section (index 5) is selected re-clamps `@section` into the now-shorter
      # range (0..4) instead of leaving it pointing at a section that no longer
      # renders. No-op when the value is unchanged or `@section` is already valid.
      def show_seconds=(value : Bool) : Bool
        return value if value == @show_seconds
        @show_seconds = value
        @section = @section.clamp(0, section_count - 1)
        update_content
        request_render
        value
      end

      def initialize(date_time : Time? = nil, show_seconds = true, **input)
        @datetime = date_time || (Time.local rescue Time.utc(2000, 1, 1))
        @show_seconds = show_seconds

        super **input
        @parse_tags = true

        handle Crysterm::Event::KeyPress
        setup_section_mouse

        update_content
      end

      def date_time : Time
        @datetime
      end

      def date_time=(value : Time) : Time
        return @datetime if value == @datetime
        @datetime = value
        update_content
        emit Crysterm::Event::DateChange, @datetime
        request_render
        @datetime
      end

      private def section_count : Int32
        show_seconds? ? 6 : 5
      end

      # Maps an absolute x to a section, by the `YYYY-MM-DD HH:MM:SS` layout
      # (19 cols, last col 18) or `YYYY-MM-DD HH:MM` with seconds hidden (16 cols,
      # last col 15). A click in the widget's trailing area past the text is off
      # the field and must return `nil`, as `Mixin::SectionedField#select_section_at`
      # relies on (it leaves the active section untouched then). Without the upper
      # bound a click right of the text fell through to the last section.
      private def section_at(x : Int32) : Int32?
        col = x - aleft - ileft
        return nil if col < 0 || col > (show_seconds? ? 18 : 15)
        sec = case col
              when .<=(4)  then 0 # YYYY (and the '-')
              when .<=(7)  then 1 # MM
              when .<=(10) then 2 # DD (and the ' ')
              when .<=(13) then 3 # HH
              when .<=(16) then 4 # MM
              else              5 # SS
              end
        sec.clamp(0, section_count - 1)
      rescue
        nil
      end

      private def update_content : Nil
        t = @datetime
        parts = [
          t.year.to_s.rjust(4, '0'),
          t.month.to_s.rjust(2, '0'),
          t.day.to_s.rjust(2, '0'),
          t.hour.to_s.rjust(2, '0'),
          t.minute.to_s.rjust(2, '0'),
          t.second.to_s.rjust(2, '0'),
        ]
        parts = highlight_part parts

        date = "#{parts[0]}-#{parts[1]}-#{parts[2]}"
        time = show_seconds? ? "#{parts[3]}:#{parts[4]}:#{parts[5]}" : "#{parts[3]}:#{parts[4]}"
        set_content "#{date} #{time}"
      end

      # Steps the active section by *delta*, wrapping within its own range without
      # carrying; the day is then clamped to the target month.
      private def step(delta : Int32) : Nil
        y, mo, d = @datetime.year, @datetime.month, @datetime.day
        h, mi, s = @datetime.hour, @datetime.minute, @datetime.second
        dim = nil
        case @section
        when 0 then y = (y + delta).clamp(1, 9999) # `Time` only supports years 1..9999
        when 1 then mo = wrap(mo - 1, delta, 12) + 1
        when 2 then d = wrap(d - 1, delta, dim = Time.days_in_month(y, mo)) + 1
        when 3 then h = wrap(h, delta, 24)
        when 4 then mi = wrap(mi, delta, 60)
        else        s = wrap(s, delta, 60)
        end
        # Reuse the day branch's count; year/month branches changed y/mo, so recompute.
        d = Math.min(d, dim || Time.days_in_month(y, mo))
        self.date_time = Time.local(y, mo, d, h, mi, s)
      end

      def on_keypress(e)
        handle_section_key e
      end
    end
  end
end
