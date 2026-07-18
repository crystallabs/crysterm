require "../../src/crysterm"

# Port of Blessed's test/widget-shrink-fail.js
#
# Outer scrollable `tab` box containing a `form` with computed height (blessed
# 'shrink' -> shrink_to_fit). Form holds three label/textbox pairs (Foo/Bar/Baz)
# and a submit button; submit collects the textbox values and emits Event::FormSubmitted.
module Crysterm
  s = Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

  tab = Widget::ScrollableBox.new \
    parent: s,
    top: 2,
    left: 0,
    right: 0,
    bottom: 0,
    scrollable: true,
    keys: true,
    vi: true,
    always_scroll: true,
    scrollbar: true

  form = Widget::Form.new \
    parent: tab,
    top: 0,
    left: 1,
    right: 1,
    shrink_to_fit: true, # blessed height:'shrink' -> shrink_to_fit: true
    keys: true,
    label: " {blue-fg}Form{/blue-fg} ", # blessed's `mouse: true` isn't a Crysterm kwarg; dropped
    parse_tags: true,
    style: Style.new(border: BorderType::Line)

  # Foo
  Widget::Text.new \
    parent: form,
    top: 0,
    left: 0,
    height: 1,
    content: "Foo",
    parse_tags: true

  Widget::LineEdit.new \
    parent: form,
    name: "foo",
    input_on_focus: true,
    top: 0,
    left: 9,
    right: 1,
    height: 1,
    style: Style.new(bg: "black")

  # Bar
  Widget::Text.new \
    parent: form,
    top: 2,
    left: 0,
    height: 1,
    content: "Bar",
    parse_tags: true

  Widget::LineEdit.new \
    parent: form,
    name: "bar",
    input_on_focus: true,
    top: 2,
    left: 9,
    right: 1,
    height: 1,
    style: Style.new(bg: "black")

  # Baz
  Widget::Text.new \
    parent: form,
    top: 4,
    left: 0,
    height: 1,
    content: "Baz",
    parse_tags: true

  Widget::LineEdit.new \
    parent: form,
    name: "baz",
    input_on_focus: true,
    top: 4,
    left: 9,
    right: 1,
    height: 1,
    style: Style.new(bg: "black")

  submit = Widget::Button.new \
    parent: form,
    name: "submit",
    top: 6,
    right: 1,
    height: 1,
    width: 10,
    content: "send",
    parse_tags: true,
    style: Style.new(bg: "black")

  submit.on(Crysterm::Event::Pressed) do
    # blessed had a buggy `tabs.send._.form.submit()` here; intent is to submit the enclosing form.
    form.submit
  end

  form.on(Crysterm::Event::FormSubmitted) do |e|
    # blessed logged the data here; no-op instead.
    _ = e.data
    s.destroy
    exit
  end

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.render
  s.exec
end
