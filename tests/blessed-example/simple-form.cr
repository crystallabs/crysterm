require "../../src/crysterm"

# Port of blessed's `example/simple-form.js`.
#
# Two-button form: "submit" submits, "cancel" resets; content reflects which
# happened. Tab/Shift-Tab move focus, Enter or click activates, q quits.
# Button colors and focus/hover state come from a CSS stylesheet.

include Crysterm

screen = Window.new title: "simple-form.cr"
screen.enable_mouse

screen.stylesheet = <<-CSS
  Form   { background-color: green; color: white; }
  Button { background-color: blue;  color: white; }
  Button:focus, Button:hover { background-color: red; }
CSS

form = Widget::Form.new(
  parent: screen,
  keys: true,
  left: 0,
  top: 0,
  width: 30,
  height: 4,
  content: "Submit or cancel?",
)

submit = Widget::Button.new(
  parent: form,
  keys: true,
  left: 10,
  top: 2,
  width: 8,
  height: 1,
  name: "submit",
  content: "{center}submit{/center}",
  parse_tags: true,
)

cancel = Widget::Button.new(
  parent: form,
  keys: true,
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
  form.set_content "Submitted."
  screen.render
end

form.on(Event::Reset) do
  form.set_content "Canceled."
  screen.render
end

screen.on(Event::KeyPress) do |e|
  exit 0 if e.char == 'q'
end

submit.focus
screen.exec
