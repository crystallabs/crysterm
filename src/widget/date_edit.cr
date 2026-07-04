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
    # Emits `Event::DateChange` whenever the date changes.
    #
    # The shared section machinery (selection, navigation, wheel/press handling)
    # lives in `Mixin::SectionedField`.
    # `DateEdit < DateTimeEdit` mirrors Qt's `QDateEdit < QDateTimeEdit`: a
    # date-only specialization keeping its own `@date` backing store, overriding
    # the section machinery (three sections instead of six) and adding the
    # calendar popup. Keyboard/mouse wiring and initial render are inherited
    # from `DateTimeEdit#initialize`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![DateEdit screenshot](../../tests/widget/date_edit/date_edit.5s.apng)
    # <!-- /widget-examples:capture -->
    class DateEdit < DateTimeEdit
      # Calendar-popup lifecycle (open flag, modal grab, outside-click dismissal,
      # grab region, teardown). We supply `#popup_widget` and `#close`.
      include Mixin::Popup

      @date : Time
      # `@section`: 0 = year, 1 = month, 2 = day (defaulted to the day below).

      # Whether Enter/Space drops a calendar popup (Qt's `setCalendarPopup`).
      property? calendar_popup : Bool = true

      @popup : Calendar?

      def initialize(date : Time? = nil, calendar_popup = true, **input)
        @date = (date || Mixin::SectionedField.default_today).at_beginning_of_day
        @calendar_popup = calendar_popup

        # `DateTimeEdit#initialize` wires the section keyboard/mouse handlers,
        # sets `@parse_tags`, and renders once (highlighting the default section).
        super **input
        @section = 2 # start on the day section
        update_content
      end

      # A press toggles the calendar popup (click to open, click again to close);
      # a wheel dismisses an open popup before stepping. (`Mixin::SectionedField`
      # hooks, run after the section under the pointer is selected.)
      protected def on_section_press : Nil
        toggle if calendar_popup?
      end

      protected def on_section_wheel : Nil
        close if @open
      end

      # Opens the calendar if closed, closes it if open.
      def toggle : Nil
        @open ? close : open
      end

      section_value date, @date, at_beginning_of_day

      private def section_count : Int32
        3
      end

      # Maps an absolute x to a section index (year/month/day at the `YYYY-MM-DD`
      # columns 0-4 / 5-7 / 8-9); `nil` when off the field. A separator column
      # belongs to the field it follows — the `-` at col 4 is part of the year and
      # the `-` at col 7 part of the month — so the inclusive end-columns 4/7/9
      # match `DateTimeEdit`'s for the shared `YYYY-MM-DD` prefix. The field is
      # exactly 10 columns (last col 9); `nil` past it leaves the active section
      # untouched (see `Mixin::SectionedField#section_from_columns`).
      # Inclusive section end-columns for the `YYYY-MM-DD` layout (year/month/day),
      # hoisted so a mouse press/wheel doesn't rebuild the array each time.
      SECTION_ENDS = [4, 7, 9]

      private def section_at(x : Int32) : Int32?
        section_from_columns x, SECTION_ENDS
      end

      private def update_content : Nil
        parts = [@date.year.to_s.rjust(4, '0'), @date.month.to_s.rjust(2, '0'), @date.day.to_s.rjust(2, '0')]
        set_content highlight_part(parts).join('-')
      end

      # Steps the active section by *delta*, wrapping within that section's own
      # range without carrying: day within month, month within year, year
      # unbounded; day then clamped to the (possibly shorter) target month. The
      # date-only sections 0/1/2 map to the year/month/day component indices
      # directly; the date carries no time, so the untouched h/m/s stay 0.
      private def step(delta : Int32) : Nil
        self.date = step_time_field @date, @section, delta
      end

      # The calendar drop-down (for `Mixin::Popup`).
      def popup_widget : ::Crysterm::Widget?
        @popup
      end

      # Drops the calendar. Grab, outside-click dismissal, and the open flag
      # come from `Mixin::Popup`.
      def open : Nil
        return if @open || !calendar_popup?
        pop = ensure_popup
        pop.date = @date
        position_popup pop
        show_popup pop
      end

      def close : Nil
        return unless teardown_popup
        focus
      end

      private def ensure_popup : Calendar
        @popup ||= begin
          cal = Calendar.new(
            window: window, top: 0, left: 0, width: 22, height: 10,
            date: @date,
          )
          cal.add_css_class "popup" # themed via `.popup { border: solid; ... }`
          cal.on(Crysterm::Event::Action) do
            self.date = cal.date
            close
          end
          # The popup holds focus while open, so Escape must be handled here to
          # dismiss it (the field's own key handler isn't focused meanwhile).
          cal.on(Crysterm::Event::KeyPress) do |e|
            if e.key == Tput::Key::Escape
              close
              e.accept
            end
          end
          window.append cal
          cal.hide
          cal
        end
      end

      # Places the calendar against the field: below when its full height fits,
      # otherwise flipped above (Qt opens upward when it would run off the
      # bottom), clamped on-window. `Overlay.place_child` owns the below/above
      # fit choice, the on-window clamp, and the single absolute→window-local
      # inset conversion (a window-appended popup's `left`/`top` are relative to
      # the window content origin), fixing the invisible/near-bottom popup and
      # the bordered-window shift the raw `atop + aheight` placement had.
      private def position_popup(pop : Calendar) : Nil
        Overlay.place_child(pop, {aleft, atop, awidth, aheight}, {pop.awidth, pop.aheight},
          Overlay::BELOW_ABOVE)
      rescue
        # Not laid out yet.
      end

      def on_keypress(e)
        if calendar_popup? && (e.key == Tput::Key::Enter || e.key == Tput::Key::Space || e.char == ' ')
          toggle
          e.accept
          request_render
          return
        end

        return if handle_section_key e

        if e.key == Tput::Key::Escape && @open
          close
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
