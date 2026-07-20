# Example: Crysterm::Widget::ComboBox
#
# Minimal, self-contained example of a single ComboBox.
# Run it:     crystal run examples/widget/combo_box/combo_box.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run("ComboBox",
  script: ->(d : WidgetExample::Driver) {
    d.hold 0.5
    d.key :enter, dwell: 0.5
    d.key :down, dwell: 0.4
    d.key :up, dwell: 0.4
    d.key :escape, dwell: 0.5
  }) do |window|
  window.stylesheet = "ComboBox { border: solid; color: #c0caf5; }"
  ComboBox.new \
    parent: window, top: "center", left: "center", width: 24, height: 3,
    options: %w[Red Green Blue Yellow], current_index: 2
end
