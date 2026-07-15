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
    # section under the pointer. Emits `Event::DateChanged` (carrying the `Time`)
    # on every change.
    #
    # Like Qt's default `QDateTimeEdit` (`calendarPopup == false`), it is edited
    # in place with no drop-down. The shared section machinery lives in
    # `Mixin::SectionedField`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![DateTimeEdit screenshot](../../tests/widget/date_time_edit/date_time_edit.5s.apng)
    # <!-- /widget-examples:capture -->
    class DateTimeEdit < AbstractSpinBox
      include Mixin::SectionedField

      @datetime : Time
      # `@section`: 0=year 1=month 2=day 3=hour 4=minute 5=second.

      # Whether the seconds section is shown and editable.
      property? show_seconds : Bool = true

      # Re-wraps the generated setter: toggling seconds off while the seconds
      # section (index 5) is selected re-clamps `@section` into range (0..4)
      # instead of pointing at a section that no longer renders.
      def show_seconds=(value : Bool) : Bool
        return value if value == @show_seconds
        @show_seconds = value
        @section = @section.clamp(0, section_count - 1)
        update_content
        request_render
        value
      end

      def initialize(date_time : Time? = nil, show_seconds = true, **input)
        @datetime = date_time || Mixin::SectionedField.default_today
        @show_seconds = show_seconds

        super **input
        @parse_tags = true

        handle Crysterm::Event::KeyPress
        setup_section_mouse

        update_content
      end

      section_value date_time, @datetime

      private def section_count : Int32
        show_seconds? ? 6 : 5
      end

      # Maps an absolute x to a section over the `YYYY-MM-DD HH:MM:SS` layout
      # (19 cols, last col 18) or `YYYY-MM-DD HH:MM` with seconds hidden (16 cols,
      # last col 15). The inclusive end-columns per section: YYYY+`-` → 4, MM → 7,
      # DD+` ` → 10, HH → 13, MM → 16, SS → 18. `nil` past the text (see
      # `Mixin::SectionedField#section_from_columns`).
      # Inclusive section end-columns for `YYYY-MM-DD HH:MM:SS` / `… HH:MM`,
      # hoisted so a mouse press/wheel doesn't rebuild the array each time.
      SECTION_ENDS_SECONDS    = [4, 7, 10, 13, 16, 18]
      SECTION_ENDS_NO_SECONDS = [4, 7, 10, 13, 15]

      private def section_at(x : Int32) : Int32?
        section_from_columns x, show_seconds? ? SECTION_ENDS_SECONDS : SECTION_ENDS_NO_SECONDS
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

      # Steps the active section by *delta* (its `@section` is the component index
      # directly), wrapping within its own range; day clamped to the target month.
      private def step(delta : Int32) : Nil
        self.date_time = step_time_field @datetime, @section, delta
      end

      def on_keypress(e)
        handle_section_key e
      end
    end
  end
end
