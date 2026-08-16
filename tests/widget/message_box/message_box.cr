# Example: Crysterm::Widget::MessageBox
#
# Minimal, self-contained example of a single MessageBox.
# Run it:     crystal run tests/widget/message_box/message_box.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "MessageBox" do |window|
  window.stylesheet = "MessageBox { border: solid; color: #c0caf5; background-color: #283457; }"
  msg = MessageBox.new parent: window, top: "center", left: "center", width: 40, height: 7
  msg.open("File saved successfully.", 999.seconds) { }
end
