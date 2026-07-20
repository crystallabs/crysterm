# Example: Crysterm::Widget::Message
#
# Minimal, self-contained example of a single Message.
# Run it:     crystal run examples/widget/message/message.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Message" do |window|
  window.stylesheet = "Message { border: solid; color: #c0caf5; background-color: #283457; }"
  msg = Message.new parent: window, top: "center", left: "center", width: 40, height: 7
  msg.display("File saved successfully.", 999.seconds) { }
end
