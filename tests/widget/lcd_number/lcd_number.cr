# Example: Crysterm::Widget::LCDNumber
#
# Minimal, self-contained example of a single LCDNumber.
# Run it:     crystal run tests/widget/lcd_number/lcd_number.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "LCDNumber" do |window|
  window.stylesheet = "LCDNumber { color: #f7768e; }"
  LCDNumber.new parent: window, top: "center", left: "center", value: 1234
end
