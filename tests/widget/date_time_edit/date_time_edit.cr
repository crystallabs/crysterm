# Example: Crysterm::Widget::DateTimeEdit
#
# Minimal, self-contained example of a single DateTimeEdit.
# Run it:     crystal run examples/widget/date_time_edit/date_time_edit.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("DateTimeEdit",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :up, times: 3, dwell: 0.4
    d.key :down, times: 3, dwell: 0.4
  }) do |window|
  window.stylesheet = "DateTimeEdit { border: solid; color: #c0caf5; }"
  dte = DateTimeEdit.new parent: window, top: "center", left: "center", width: 26, height: 3, date_time: Time.utc(2026, 6, 24, 13, 37, 5)
  dte.focus
end
