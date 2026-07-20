# Example: Crysterm::Widget::Slider
#
# Minimal, self-contained example of a single Slider.
# Run it:     crystal run examples/widget/slider/slider.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("Slider",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :right, times: 5, dwell: 0.3
    d.key :left, times: 5, dwell: 0.3
  }) do |window|
  window.stylesheet = "Slider { color: #bb9af7; }"
  slider = Slider.new parent: window, top: "center", left: "center", width: 40, height: 1, value: 40
  slider.focus
end
