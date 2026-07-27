# Example: Crysterm::Widget::LCDNumber
#
# Minimal, self-contained example of a single LCDNumber.
# Run it:     crystal run examples/widget/lcd_number/lcd_number.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "LCDNumber" do |screen|
  screen.stylesheet = "LCDNumber { color: #f7768e; }"
  Crysterm::Widget::LCDNumber.new parent: screen, top: "center", left: "center", value: 1234
end
