# Example: Crysterm::Widget::ToolTip
#
# Minimal, self-contained example of a single ToolTip.
# Run it:     crystal run examples/widget/tooltip/tooltip.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "ToolTip" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; } Tooltip { border: solid; color: #1a1a2e; background-color: #e0af68; }"
  Widget::Box.new parent: window, top: 3, left: 4, width: 24, height: 3,
    content: "{center}Hover target{/center}", parse_tags: true
  # Tooltip pops up just below the hovered target.
  tt = ToolTip.new parent: window
  tt.show_at 6, 6, "A helpful tooltip"
end
