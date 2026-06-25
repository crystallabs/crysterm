# Example: Crysterm::Widget::SizeGrip
#
# Minimal, self-contained example of a single SizeGrip.
# Run it:     crystal run examples/widget/size_grip/size_grip.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "SizeGrip" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; } SizeGrip { color: #7aa2f7; }"
  Crysterm::Widget::Box.new parent: screen, top: 2, left: 2, width: 40, height: 14,
    content: " A resizable panel — the grip sits in its corner."
  Crysterm::Widget::SizeGrip.new parent: screen, top: 15, left: 41
end
