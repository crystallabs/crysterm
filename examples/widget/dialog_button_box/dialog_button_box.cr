# Example: Crysterm::Widget::DialogButtonBox
#
# Minimal, self-contained example of a single DialogButtonBox.
# Run it:     crystal run examples/widget/dialog_button_box/dialog_button_box.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "DialogButtonBox" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; } Button { color: #c0caf5; }"
  Crysterm::Widget::Box.new parent: screen, top: "center", left: "center", width: 46, height: 8,
    content: "{center}\nSave changes before closing?{/center}", parse_tags: true
  Crysterm::Widget::DialogButtonBox.new \
    parent: screen, top: "50%+2", left: "center", width: 40, height: 1,
    buttons: Crysterm::Widget::DialogButtonBox::StandardButton::Ok | Crysterm::Widget::DialogButtonBox::StandardButton::Cancel
end
