# Example: Crysterm::Widget::Calendar
#
# Minimal, self-contained example of a single Calendar.
# Run it:     crystal run tests/widget/calendar/calendar.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run("Calendar",
  script: ->(d : CT::WidgetExample::Driver) {
    d.hold 0.5
    d.key :right, times: 3, dwell: 0.35
    d.key :down, times: 2, dwell: 0.4
    d.key :up, times: 2, dwell: 0.4
    d.key :left, times: 3, dwell: 0.35
  }) do |window|
  window.stylesheet = "Calendar { border: solid; }"
  cal = CW::Calendar.new parent: window, top: "center", left: "center", date: Time.utc(2026, 6, 24)
  cal.focus
end
