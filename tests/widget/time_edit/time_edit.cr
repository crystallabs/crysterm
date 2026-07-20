# Example: Crysterm::Widget::TimeEdit
#
# Minimal, self-contained example of a single TimeEdit.
# Run it:     crystal run examples/widget/time_edit/time_edit.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("TimeEdit",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :up, times: 3, dwell: 0.4
    d.key :down, times: 3, dwell: 0.4
  }) do |window|
  window.stylesheet = "TimeEdit { border: solid; color: #c0caf5; }"
  te = TimeEdit.new parent: window, top: "center", left: "center", width: 14, height: 3, time: Time.utc(2026, 6, 24, 13, 37, 5)
  te.focus
end
