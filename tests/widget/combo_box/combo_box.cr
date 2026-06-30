# Example: Crysterm::Widget::ComboBox
#
# Minimal, self-contained example of a single ComboBox.
# Run it:     crystal run examples/widget/combo_box/combo_box.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("ComboBox",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :enter, dwell: 0.5
    d.key :down, dwell: 0.4
    d.key :up, dwell: 0.4
    d.key :escape, dwell: 0.5
  }) do |screen|
  screen.stylesheet = "ComboBox { border: solid; color: #c0caf5; }"
  Crysterm::Widget::ComboBox.new \
    parent: screen, top: "center", left: "center", width: 24, height: 3,
    options: %w[Red Green Blue Yellow], selected: 2
end
