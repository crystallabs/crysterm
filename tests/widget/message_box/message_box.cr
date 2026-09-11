# Example: Crysterm::Widget::MessageBox
#
# Minimal, self-contained example of a single MessageBox.
# Run it:     crystal run tests/widget/message_box/message_box.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "MessageBox" do |window|
  window.stylesheet = "MessageBox { border: solid; color: #c0caf5; background-color: #283457; }"
  msg = CW::MessageBox.new parent: window, top: "center", left: "center", width: 40, height: 7
  msg.open("File saved successfully.", 999.seconds) { }
end
