# Example: Crysterm::Widget::ToolBox
#
# Minimal, self-contained example of a single ToolBox.
# Run it:     crystal run examples/widget/toolbox/toolbox.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "ToolBox" do |window|
  window.stylesheet = "ToolBox { border: solid; color: #c0caf5; }"
  tbx = ToolBox.new parent: window, top: "center", left: "center", width: 36, height: 14
  tbx.add_item "General", Widget::Box.new(content: "Theme, language, startup")
  tbx.add_item "Editor", Widget::Box.new(content: "Tabs, wrap, font size")
  tbx.add_item "Advanced", Widget::Box.new(content: "Proxies, caches, flags")
end
