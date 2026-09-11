# Example: Crysterm::Widget::Form
#
# Minimal, self-contained example of a single Form.
# Run it:     crystal run tests/widget/form/form.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run("Form",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :tab, times: 2, dwell: 0.5
    d.key :backtab, times: 2, dwell: 0.5
  }) do |window|
  window.stylesheet = "Form { border: solid; color: #c0caf5; } LineEdit { background-color: #1f2335; }"
  form = CW::Form.new parent: window, top: "center", left: "center", width: 42, height: 10, label: " Sign in "
  CW::Box.new parent: form, top: 1, left: 2, content: "User:"
  u = CW::LineEdit.new parent: form, top: 1, left: 9, width: 26, height: 1
  u.value = "ada"
  CW::Box.new parent: form, top: 3, left: 2, content: "Pass:"
  p = CW::LineEdit.new parent: form, top: 3, left: 9, width: 26, height: 1, echo_mode: :no_echo
  p.value = "secret"
end
