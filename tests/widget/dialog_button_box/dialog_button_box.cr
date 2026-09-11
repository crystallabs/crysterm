# Example: Crysterm::Widget::DialogButtonBox
#
# Minimal, self-contained example of a single DialogButtonBox.
# Run it:     crystal run tests/widget/dialog_button_box/dialog_button_box.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "DialogButtonBox" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; } Button { color: #c0caf5; }"
  CW::Box.new parent: window, top: "center", left: "center", width: 46, height: 8,
    content: "{center}\nSave changes before closing?{/center}", parse_tags: true
  CW::DialogButtonBox.new \
    parent: window, top: "50%+2", left: "center", width: 40, height: 1,
    buttons: CW::DialogButtonBox::StandardButton::Ok | CW::DialogButtonBox::StandardButton::Cancel
end
