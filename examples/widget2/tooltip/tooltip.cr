# Example: Crysterm::Widget::ToolTip
#
# Minimal, self-contained example of a single ToolTip.
# Run it:     crystal run examples/widget/tooltip/tooltip.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "ToolTip" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; } Tooltip { border: solid; color: #1a1a2e; background-color: #e0af68; }"
  Crysterm::Widget::Box.new parent: screen, top: 3, left: 4, width: 24, height: 3,
    content: "{center}Hover target{/center}", parse_tags: true
  # The tooltip pops up just below the hovered target.
  tt = Crysterm::Widget::ToolTip.new parent: screen
  tt.show_at 6, 6, "A helpful tooltip"
end
