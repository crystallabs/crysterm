require "./date_time_edit"
require "./calendar"
require "../mixin/popup"

module Crysterm
  class Widget
    # Date entry field, modeled after Qt's `QDateEdit`.
    #
    # Shows a `YYYY-MM-DD` date with one *section* highlighted. Left/Right move
    # between the year/month/day sections; Up/Down step the active section,
    # wrapping within its own range without carrying (day within the month,
    # month within the year). The mouse wheel steps the section *under the
    # pointer* (so the year and month are adjustable too, not just the day).
    # When `#calendar_popup?`, clicking the field — or Enter/Space — toggles a
    # `Widget::Calendar` to pick a day (clicking again, or Escape, closes it).
    # Emits `Event::DateChanged` whenever the date changes.
    #
    # <!-- widget-examples:capture v1 -->
    # ![DateEdit screenshot](../../tests/widget/date_edit/date_edit.5s.apng)
    # <!-- /widget-examples:capture -->
    class DateEdit < DateTimeEdit
      include Mixin::Popup

      @date : Time
      # `@section`: 0 = year, 1 = month, 2 = day (defaulted to the day below).

      # Whether Enter/Space drops a calendar popup (Qt's `setCalendarPopup`).
      property? calendar_popup : Bool = true

      @popup : Calendar?

      def initialize(date : Time? = nil, calendar_popup = true, **input)
        @date = (date || Mixin::SectionedField.default_today).at_beginning_of_day
        @calendar_popup = calendar_popup

        super **input
        @section = 2 # start on the day section
        update_content
      end

      # A press toggles the calendar popup; a wheel dismisses an open one before
      # stepping.
      protected def on_section_press : Nil
        toggle_popup if calendar_popup?
      end

      protected def on_section_wheel : Nil
        hide_popup if @open
      end

      section_value date, @date, at_beginning_of_day

      private def section_count : Int32
        3
      end

      # Inclusive section end-columns for the `YYYY-MM-DD` layout (year/month/day);
      # hoisted so a mouse press/wheel doesn't rebuild the array each time. A
      # separator column belongs to the field it follows, so these must match
      # `DateTimeEdit`'s for the shared `YYYY-MM-DD` prefix.
      SECTION_ENDS = [4, 7, 9]

      # Maps an absolute x to a section index; `nil` when off the field, which
      # leaves the active section untouched.
      private def section_at(x : Int32) : Int32?
        section_from_columns x, SECTION_ENDS
      end

      private def update_content : Nil
        parts = [@date.year.to_s.rjust(4, '0'), @date.month.to_s.rjust(2, '0'), @date.day.to_s.rjust(2, '0')]
        set_content highlight_part(parts).join('-')
      end

      # Steps the active section by *delta*, wrapping within that section's own
      # range without carrying: day within month, month within year, year
      # unbounded; day then clamped to the (possibly shorter) target month.
      private def step(delta : Int32) : Nil
        self.date = step_time_field @date, @section, delta
      end

      # The calendar drop-down.
      def popup_widget : ::Crysterm::Widget?
        @popup
      end

      # Extends the modal grab region to cover the calendar's own month/year nav
      # dropdowns. They are window-level siblings that overhang the calendar's
      # rectangle, so without this a click on one reads as a click-away and
      # dismisses the whole calendar instead of only the dropdown.
      def grab_contains?(x : Int32, y : Int32) : Bool
        super || (@popup.try(&.nav_popup_contains?(x, y)) || false)
      end

      # Drops the calendar (Qt's `showPopup`).
      def show_popup : Nil
        return if @open || !calendar_popup?
        pop = ensure_popup
        pop.date = @date
        position_popup pop
        present_popup pop
      end

      # Dismisses the calendar (Qt's `hidePopup`).
      def hide_popup : Nil
        return unless teardown_popup
        focus
      end

      private def ensure_popup : Calendar
        # The calendar is a *window* child, not ours, so a cross-window reparent
        # strands it on the old window. Drop it and rebuild on the current one.
        if (stale = @popup) && stale.window? != window?
          ::Crysterm::Widget.destroy_satellite stale
          @popup = nil
        end
        @popup ||= begin
          cal = Calendar.new(
            window: window, top: 0, left: 0, width: 22, height: 10,
            date: @date,
          )
          cal.add_css_class "popup" # themed via `.popup { border: solid; ... }`
          cal.on(Crysterm::Event::DateActivated) do
            self.date = cal.date
            hide_popup
          end
          # The popup holds focus while open, so Escape must be handled here to
          # dismiss it (the field's own key handler isn't focused meanwhile).
          cal.on(Crysterm::Event::KeyPress) do |e|
            if e.key == Tput::Key::Escape
              hide_popup
              e.accept
            end
          end
          window.append cal
          cal.hide
          cal
        end
      end

      # Places the calendar against the field: below when its full height fits,
      # otherwise flipped above, clamped on-window.
      private def position_popup(pop : Calendar) : Nil
        Overlay.place_child(pop, {aleft, atop, awidth, aheight}, {pop.awidth, pop.aheight},
          Overlay::BELOW_ABOVE)
      rescue
        # Not laid out yet.
      end

      def on_keypress(e)
        if calendar_popup? && (e.key == Tput::Key::Enter || e.key == Tput::Key::Space || e.char == ' ')
          toggle_popup
          e.accept
          request_render
          return
        end

        return if handle_section_key e

        if e.key == Tput::Key::Escape && @open
          hide_popup
          e.accept
          request_render
        end
      end

      def destroy
        teardown_popup_on_destroy
        @popup = nil
        super
      end
    end
  end
end
