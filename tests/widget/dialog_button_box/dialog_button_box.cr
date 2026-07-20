# Example: Crysterm::Widget::DialogButtonBox
#
# Minimal, self-contained example of a single DialogButtonBox.
# Run it:     crystal run examples/widget/dialog_button_box/dialog_button_box.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "DialogButtonBox" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; } Button { color: #c0caf5; }"
  Widget::Box.new parent: window, top: "center", left: "center", width: 46, height: 8,
    content: "{center}\nSave changes before closing?{/center}", parse_tags: true
  DialogButtonBox.new \
    parent: window, top: "50%+2", left: "center", width: 40, height: 1,
    buttons: DialogButtonBox::StandardButton::Ok | DialogButtonBox::StandardButton::Cancel
end
