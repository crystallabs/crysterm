# Example: Crysterm::Widget::InputDialog
#
# Minimal, self-contained example of a single InputDialog.
# Run it:     crystal run tests/widget/input_dialog/input_dialog.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "InputDialog" do |window|
  window.stylesheet = "InputDialog { border: solid; color: #c0caf5; }"
  InputDialog.new \
    parent: window, top: "center", left: "center", width: 46, height: 7,
    content: "What is your name?"
end
