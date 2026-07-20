# Example: Crysterm::Widget::ToolBar
#
# Minimal, self-contained example of a single ToolBar.
# Run it:     crystal run examples/widget/tool_bar/tool_bar.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "ToolBar" do |window|
  window.stylesheet = "ToolBar { color: #c0caf5; }"
  tb = ToolBar.new parent: window, top: 0, left: 0, width: "100%"
  %w[New Open Save Cut Copy Paste].each { |t| tb.add_button(t) { } }
end
