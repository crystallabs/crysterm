require "../../src/crysterm"

# Port of blessed's `example/simple-form.js`.
#
# Two-button form: "submit" submits, "cancel" resets; content reflects which
# happened. Tab/Shift-Tab move focus, Enter or click activates, q quits.
# Button colors and focus/hover state come from a CSS stylesheet.

include Crysterm
include Crysterm::Widgets

window = Window.new title: "simple-form.cr"
window.enable_mouse

window.stylesheet = <<-CSS
  Form   { background-color: green; color: white; }
  Button { background-color: blue;  color: white; }
  Button:focus, Button:hover { background-color: red; }
CSS

form = Form.new(
  parent: window,
  left: 0,
  top: 0,
  width: 30,
  height: 4,
  content: "Submit or cancel?",
)

submit = Button.new(
  parent: form,
  left: 10,
  top: 2,
  width: 8,
  height: 1,
  name: "submit",
  content: "{center}submit{/center}",
  parse_tags: true,
)

cancel = Button.new(
  parent: form,
  left: 20,
  top: 2,
  width: 8,
  height: 1,
  name: "cancel",
  content: "{center}cancel{/center}",
  parse_tags: true,
)

submit.on_click { form.submit }
cancel.on_click { form.reset }

form.on(Event::FormSubmitted) do
  form.content = "Submitted."
end

form.on(Event::Reset) do
  form.content = "Canceled."
end

submit.focus
window.exec
