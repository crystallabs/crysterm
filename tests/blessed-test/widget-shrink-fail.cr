require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-shrink-fail.js
#
# Outer scrollable `tab` box containing a `form` with computed height (blessed
# 'shrink' -> shrink_to_fit). Form holds three label/textbox pairs (Foo/Bar/Baz)
# and a submit button; submit collects the textbox values and emits CT::Event::FormSubmitted.

s = CT::Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

tab = CW::ScrollableBox.new \
  parent: s,
  top: 2,
  left: 0,
  right: 0,
  bottom: 0,
  scrollable: true,
  keys: true,
  vi_keys: true,
  always_scroll: true,
  scrollbar_policy: :as_needed

form = CW::Form.new \
  parent: tab,
  top: 0,
  left: 1,
  right: 1,
  shrink_to_fit: true, # blessed height:'shrink' -> shrink_to_fit: true
  keys: true,
  label: " {blue-fg}Form{/blue-fg} ", # blessed's `mouse: true` isn't a Crysterm kwarg; dropped
  parse_tags: true,
  style: CT::Style.new(border: CT::BorderType::Solid)

# Foo
CW::Text.new \
  parent: form,
  top: 0,
  left: 0,
  height: 1,
  content: "Foo"

CW::LineEdit.new \
  parent: form,
  name: "foo",
  input_on_focus: true,
  top: 0,
  left: 9,
  right: 1,
  height: 1,
  style: CT::Style.new(bg: "black")

# Bar
CW::Text.new \
  parent: form,
  top: 2,
  left: 0,
  height: 1,
  content: "Bar"

CW::LineEdit.new \
  parent: form,
  name: "bar",
  input_on_focus: true,
  top: 2,
  left: 9,
  right: 1,
  height: 1,
  style: CT::Style.new(bg: "black")

# Baz
CW::Text.new \
  parent: form,
  top: 4,
  left: 0,
  height: 1,
  content: "Baz"

CW::LineEdit.new \
  parent: form,
  name: "baz",
  input_on_focus: true,
  top: 4,
  left: 9,
  right: 1,
  height: 1,
  style: CT::Style.new(bg: "black")

submit = CW::Button.new \
  parent: form,
  name: "submit",
  top: 6,
  right: 1,
  height: 1,
  width: 10,
  content: "send",
  style: CT::Style.new(bg: "black")

submit.on_click do
  # blessed had a buggy `tabs.send._.form.submit()` here; intent is to submit the enclosing form.
  form.submit
end

form.on(CT::Event::FormSubmitted) do |e|
  # blessed logged the data here; no-op instead.
  _ = e.data
  s.destroy
  exit
end

s.on(CT::Event::KeyPress) do |e|
  if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.update
s.exec
