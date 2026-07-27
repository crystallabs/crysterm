# Example: Crysterm::Widget::Graph::Donut
#
# Minimal, self-contained example of a single Donut.
# Run it:     crystal run examples/widget/graph/donut/donut.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run("Donut",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    # Ramp the value up and back to its initial 65 (read-only widget, no keys —
    # reach it via the screen and set #value, guarded by the concrete type).
    [65, 75, 85, 95, 85, 75, 65].each do |v|
      d.act(dwell: 0.4) { |s| s.children.each { |c| c.value = v if c.is_a?(Crysterm::Widget::Graph::Donut) } }
    end
  }) do |screen|
  # No show_track: the braille backend is one colour per cell, so a track
  # ring's dim "off" dots can't be distinguished and just clutter the arc.
  Crysterm::Widget::Graph::Donut.new parent: screen, top: "center", left: "center", width: 24, height: 12, value: 65
end
