# Example: Crysterm::Widget::Message
#
# Minimal, self-contained example of a single Message.
# Run it:     crystal run examples/widget/message/message.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Message" do |screen|
  screen.stylesheet = "Message { border: solid; color: #c0caf5; background-color: #283457; }"
  msg = Crysterm::Widget::Message.new parent: screen, top: "center", left: "center", width: 40, height: 7
  msg.display("File saved successfully.", 999.seconds) { }
end
