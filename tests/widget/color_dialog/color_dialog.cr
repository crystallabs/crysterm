# Example: Crysterm::Widget::ColorDialog
#
# Minimal, self-contained example of a single ColorDialog.
# Run it:     crystal run examples/widget/color_dialog/color_dialog.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run "ColorDialog" do |window|
  window.stylesheet = "ColorDialog { border: solid; }"
  # Wants roughly 56x20 (see class docs); smaller and children spill past the border.
  ColorDialog.new parent: window, top: "center", left: "center", width: 56, height: 20
end
