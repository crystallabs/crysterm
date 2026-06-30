# Example: Crysterm::Widget::ToolBox
#
# Minimal, self-contained example of a single ToolBox.
# Run it:     crystal run examples/widget/toolbox/toolbox.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "ToolBox" do |screen|
  screen.stylesheet = "ToolBox { border: solid; color: #c0caf5; }"
  tbx = Crysterm::Widget::ToolBox.new parent: screen, top: "center", left: "center", width: 36, height: 14
  tbx.add_item "General", Crysterm::Widget::Box.new(content: "Theme, language, startup")
  tbx.add_item "Editor", Crysterm::Widget::Box.new(content: "Tabs, wrap, font size")
  tbx.add_item "Advanced", Crysterm::Widget::Box.new(content: "Proxies, caches, flags")
end
