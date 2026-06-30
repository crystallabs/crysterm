# Example: Crysterm::Widget::ToolBar
#
# Minimal, self-contained example of a single ToolBar.
# Run it:     crystal run examples/widget/tool_bar/tool_bar.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "ToolBar" do |screen|
  screen.stylesheet = "ToolBar { color: #c0caf5; }"
  tb = Crysterm::Widget::ToolBar.new parent: screen, top: 0, left: 0, width: "100%"
  %w[New Open Save Cut Copy Paste].each { |t| tb.add_button(t) { } }
end
