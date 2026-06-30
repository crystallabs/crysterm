# Example: Crysterm::Widget::ColorDialog
#
# Minimal, self-contained example of a single ColorDialog.
# Run it:     crystal run examples/widget/color_dialog/color_dialog.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "ColorDialog" do |screen|
  screen.stylesheet = "ColorDialog { border: solid; }"
  # ColorDialog lays out its own gradient field, hue bar and RGB/HSV spin
  # boxes; it wants roughly 56x20 (see the class docs) — too small a box and
  # its children spill past the border.
  Crysterm::Widget::ColorDialog.new parent: screen, top: "center", left: "center", width: 56, height: 20
end
