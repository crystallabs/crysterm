# Example: Crysterm::Widget::Dial
#
# Minimal, self-contained example of a single Dial.
# Run it:     crystal run examples/widget/dial/dial.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("Dial",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :up, times: 4, dwell: 0.35
    d.key :down, times: 4, dwell: 0.35
  }) do |window|
  window.stylesheet = "Dial { border: solid; color: #7aa2f7; }"
  dial = Dial.new parent: window, top: "center", left: "center", width: 21, height: 11, value: 65
  dial.focus
end
