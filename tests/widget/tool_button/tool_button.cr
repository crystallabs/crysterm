# Example: Crysterm::Widget::ToolButton
#
# Minimal, self-contained example of a single ToolButton.
# Run it:     crystal run tests/widget/tool_button/tool_button.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "ToolButton" do |window|
  window.stylesheet = "ToolButton { border: solid; background-color: #394b70; color: #c0caf5; }"
  CW::ToolButton.new parent: window, top: "center", left: "center", width: 14, height: 3, content: " Format ▾"
end
