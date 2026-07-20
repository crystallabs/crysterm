# Example: Crysterm::Widget::DateEdit
#
# Minimal, self-contained example of a single DateEdit.
# Run it:     crystal run examples/widget/date_edit/date_edit.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run("DateEdit",
  script: ->(d : WidgetExample::Driver) {
    d.hold 0.5
    d.key :enter, dwell: 0.6
    d.key :right, times: 3, dwell: 0.35
    d.key :down, dwell: 0.4
    d.key :escape, dwell: 0.6
  }) do |window|
  window.stylesheet = "DateEdit { border: solid; color: #c0caf5; }"
  de = DateEdit.new parent: window, top: "center", left: "center", width: 16, height: 3, date: Time.utc(2026, 6, 24)
  de.focus
end
