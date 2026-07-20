# Example: Crysterm::Widget::StatusBar
#
# Minimal, self-contained example of a single StatusBar.
# Run it:     crystal run examples/widget/status_bar/status_bar.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "StatusBar" do |window|
  window.stylesheet = "StatusBar { color: #c0caf5; background-color: #283457; }"
  sb = StatusBar.new parent: window, bottom: 0, left: 0, width: "100%", height: 1
  sb.show_message "Ready"
  sb.add_permanent "Ln 12, Col 4"
  sb.add_permanent "UTF-8"
end
