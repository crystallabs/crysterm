# Example: Crysterm::Widget::ColorDialog
#
# Minimal, self-contained example of a single ColorDialog.
# Run it:     crystal run tests/widget/color_dialog/color_dialog.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "ColorDialog" do |window|
  window.stylesheet = "ColorDialog { border: solid; }"
  # Wants roughly 56x20 (see class docs); smaller and children spill past the border.
  CW::ColorDialog.new parent: window, top: "center", left: "center", width: 56, height: 20
end
