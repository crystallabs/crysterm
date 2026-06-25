# Example: Crysterm::Widget::Pine::StatusBar
#
# Minimal, self-contained example of a single StatusBar.
# Run it:     crystal run examples/widget/pine/status_bar/status_bar.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "StatusBar" do |screen|
  screen.stylesheet = "StatusBar { border: solid; }"
  Crysterm::Widget::Pine::StatusBar.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    content: "{center}StatusBar{/center}", parse_tags: true
end
