# Example: Crysterm::Widget::GaugeList
#
# Minimal, self-contained example of a single GaugeList.
# Run it:     crystal run examples/widget/gauge_list/gauge_list.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("GaugeList",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    # Ramp the gauges and return to the initial set (reach the widget via the screen).
    [[72.0, 48.0, 91.0], [88.0, 64.0, 76.0], [96.0, 80.0, 62.0], [88.0, 64.0, 76.0], [72.0, 48.0, 91.0]].each do |vals|
      d.act(dwell: 0.45) { |s| s.children.each { |c| vals.each_with_index { |v, i| c[i] = v if i < c.items.size } if c.is_a?(Crysterm::Widget::GaugeList) } }
    end
  }) do |screen|
  screen.stylesheet = "GaugeList { border: solid; }"
  gl = Crysterm::Widget::GaugeList.new parent: screen, top: "center", left: "center", width: 46, height: 9
  gl.add_item "CPU", 72
  gl.add_item "Memory", 48
  gl.add_item "Disk", 91
end
