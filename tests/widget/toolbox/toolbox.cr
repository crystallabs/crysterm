# Example: Crysterm::Widget::ToolBox
#
# Minimal, self-contained example of a single ToolBox.
# Run it:     crystal run tests/widget/toolbox/toolbox.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "ToolBox" do |window|
  window.stylesheet = "ToolBox { border: solid; color: #c0caf5; }"
  tbx = CW::ToolBox.new parent: window, top: "center", left: "center", width: 36, height: 14
  tbx.add_item "General", CW::Box.new(content: "Theme, language, startup")
  tbx.add_item "Editor", CW::Box.new(content: "Tabs, wrap, font size")
  tbx.add_item "Advanced", CW::Box.new(content: "Proxies, caches, flags")
end
