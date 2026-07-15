require "./date_time_edit"

module Crysterm
  class Widget
    # Time entry field, modeled after Qt's `QTimeEdit`.
    #
    # Shows an `HH:MM:SS` time with one *section* highlighted. Click a section
    # to select it; Left/Right also move between hour/minute/second sections;
    # Up/Down or the mouse wheel step the active one (wraps within its range,
    # without carrying into the next). Emits `Event::DateChanged` (carrying a
    # `Time`) whenever the time changes.
    #
    # Like Qt's `QTimeEdit`, it's edited in place (no drop-down) — a click
    # selects the clicked section rather than opening a popup. Shared section
    # machinery lives in `Mixin::SectionedField`.
    #
    # The value is held as a `Time` so it composes with `DateEdit`/`Calendar`;
    # only its hour/minute/second are shown and edited.
    #
    # <!-- widget-examples:capture v1 -->
    # ![TimeEdit screenshot](../../tests/widget/time_edit/time_edit.5s.apng)
    # <!-- /widget-examples:capture -->
    class TimeEdit < DateTimeEdit
      @time : Time

      # `@section`: 0 = hour, 1 = minute, 2 = second (default hour, from the mixin).

      def initialize(time : Time? = nil, show_seconds = true, **input)
        @time = time || Mixin::SectionedField.default_today
        # `DateTimeEdit#initialize` defaults `@show_seconds` to true, so apply
        # our own and re-render afterwards.
        super **input
        @show_seconds = show_seconds
        update_content
      end

      section_value time, @time

      private def section_count : Int32
        show_seconds? ? 3 : 2
      end

      # Inclusive section end-columns for `HH:MM:SS` / `HH:MM`: sections sit at
      # columns 0-1 / 3-4 / 6-7, each `:` belonging to the field before it.
      # Hoisted so a mouse press/wheel doesn't rebuild the array each time.
      SECTION_ENDS_SECONDS    = [2, 5, 7]
      SECTION_ENDS_NO_SECONDS = [2, 4]

      # Maps an absolute x to a section index; `nil` past the text leaves the
      # active section untouched.
      private def section_at(x : Int32) : Int32?
        section_from_columns x, show_seconds? ? SECTION_ENDS_SECONDS : SECTION_ENDS_NO_SECONDS
      end

      private def update_content : Nil
        parts = [@time.hour.to_s.rjust(2, '0'), @time.minute.to_s.rjust(2, '0')]
        parts << @time.second.to_s.rjust(2, '0') if show_seconds?
        set_content highlight_part(parts).join(':')
      end

      # Steps the active section by *delta*, wrapping within its own range. The
      # time sections 0/1/2 (hour/minute/second) are the component indices 3/4/5,
      # so offset `@section` by 3; the date component is left untouched.
      private def step(delta : Int32) : Nil
        self.time = step_time_field @time, @section + 3, delta
      end
    end
  end
end
