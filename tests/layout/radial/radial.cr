# Example: Crysterm::Layout::Radial
#
# Minimal, self-contained example of a single Radial.
# Run it:     crystal run tests/layout/radial/radial.cr
require "../../widget/example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run "Radial" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = Widget::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: Layout::Radial.new
  # Eight fixed-size children spread evenly around the ring, the first at
  # 12 o'clock (the default start_angle of -90°).
  8.times do |i|
    Widget::Box.new parent: container, width: 9, height: 3,
      content: "{center}##{i + 1}{/center}", parse_tags: true
  end
end
