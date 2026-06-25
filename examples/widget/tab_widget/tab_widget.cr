# Example: Crysterm::Widget::TabWidget
#
# Minimal, self-contained example of a single TabWidget.
# Run it:     crystal run examples/widget/tab_widget/tab_widget.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("TabWidget",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.click 16, 0, dwell: 0.7
    d.click 28, 0, dwell: 0.7
    d.click 5, 0, dwell: 0.7
  }) do |screen|
  screen.stylesheet = "TabWidget { color: #c0caf5; }"
  tw = Crysterm::Widget::TabWidget.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
  tw.add_tab "Overview", Crysterm::Widget::Box.new(content: "{center}Overview page{/center}", parse_tags: true)
  tw.add_tab "Details", Crysterm::Widget::Box.new(content: "{center}Details page{/center}", parse_tags: true)
  tw.add_tab "Settings", Crysterm::Widget::Box.new(content: "{center}Settings page{/center}", parse_tags: true)
end
