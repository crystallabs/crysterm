# Example: Crysterm::Widget::Form
#
# Minimal, self-contained example of a single Form.
# Run it:     crystal run examples/widget/form/form.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("Form",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :tab, times: 2, dwell: 0.5
    d.key :backtab, times: 2, dwell: 0.5
  }) do |window|
  window.stylesheet = "Form { border: solid; color: #c0caf5; } LineEdit { background-color: #1f2335; }"
  form = Form.new parent: window, top: "center", left: "center", width: 42, height: 10, label: " Sign in "
  Widget::Box.new parent: form, top: 1, left: 2, content: "User:"
  u = LineEdit.new parent: form, top: 1, left: 9, width: 26, height: 1
  u.value = "ada"
  Widget::Box.new parent: form, top: 3, left: 2, content: "Pass:"
  p = LineEdit.new parent: form, top: 3, left: 9, width: 26, height: 1, echo_mode: :no_echo
  p.value = "secret"
end
