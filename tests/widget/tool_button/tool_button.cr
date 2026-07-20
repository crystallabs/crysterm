# Example: Crysterm::Widget::ToolButton
#
# Minimal, self-contained example of a single ToolButton.
# Run it:     crystal run examples/widget/tool_button/tool_button.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "ToolButton" do |window|
  window.stylesheet = "ToolButton { border: solid; background-color: #394b70; color: #c0caf5; }"
  ToolButton.new parent: window, top: "center", left: "center", width: 14, height: 3, content: " Format ▾"
end
