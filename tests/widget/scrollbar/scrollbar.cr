# Example: Crysterm::Widget::ScrollBar
#
# Minimal, self-contained example of a single ScrollBar.
# Run it:     crystal run examples/widget/scrollbar/scrollbar.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "ScrollBar" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; } ScrollBar { color: #7aa2f7; }"
  Crysterm::Widget::Box.new parent: screen, top: 2, left: 2, width: 42, height: 16,
    content: (1..30).map { |i| " Content line #{i}" }.join("\n")
  # Vertical scrollbar is one column wide; thumb sits at `value`.
  Crysterm::Widget::ScrollBar.new parent: screen, top: 2, left: 45, width: 1, height: 16, orientation: :vertical, value: 35
end
