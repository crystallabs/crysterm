# Example: Crysterm::Widget::Gauge
#
# Minimal, self-contained example of a single Gauge.
# Run it:     crystal run examples/widget/gauge/gauge.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("Gauge",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    # Ramp the value up and back to its initial 65 (read-only widget, no keys —
    # reach it via the screen and set #value, guarded by the concrete type).
    [65, 75, 85, 95, 85, 75, 65].each do |v|
      d.act(dwell: 0.4) { |s| s.children.each { |c| c.value = v if c.is_a?(Crysterm::Widget::Gauge) } }
    end
  }) do |screen|
  screen.stylesheet = "Gauge { border: solid; color: #7aa2f7; }"
  g = Crysterm::Widget::Gauge.new parent: screen, top: "center", left: "center", width: 40, height: 3
  g.value = 65
end
