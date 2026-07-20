# Example: Crysterm::Widget::Calendar
#
# Minimal, self-contained example of a single Calendar.
# Run it:     crystal run examples/widget/calendar/calendar.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run("Calendar",
  script: ->(d : WidgetExample::Driver) {
    d.hold 0.5
    d.key :right, times: 3, dwell: 0.35
    d.key :down, times: 2, dwell: 0.4
    d.key :up, times: 2, dwell: 0.4
    d.key :left, times: 3, dwell: 0.35
  }) do |window|
  window.stylesheet = "Calendar { border: solid; }"
  cal = Calendar.new parent: window, top: "center", left: "center", date: Time.utc(2026, 6, 24)
  cal.focus
end
