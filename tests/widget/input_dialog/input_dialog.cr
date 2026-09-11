# Example: Crysterm::Widget::InputDialog
#
# Minimal, self-contained example of a single InputDialog.
# Run it:     crystal run tests/widget/input_dialog/input_dialog.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "InputDialog" do |window|
  window.stylesheet = "InputDialog { border: solid; color: #c0caf5; }"
  CW::InputDialog.new \
    parent: window, top: "center", left: "center", width: 46, height: 7,
    content: "What is your name?"
end
