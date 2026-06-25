require "../../src/crysterm"

# Port of Blessed's test/widget-shrink-fail.js
#
# An outer scrollable `tab` box containing a `form` whose height is computed
# (blessed 'shrink' -> resizable). The form holds three label/textbox pairs
# (Foo/Bar/Baz) and a submit button. Pressing submit collects the textbox
# values and emits Event::SubmitData.
module Crysterm
  s = Screen.new always_propagate: [::Tput::Key::CtrlQ]

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
    # NOTE: blessed height:'shrink' -> resizable: true (form height is computed)
    resizable: true,
    keys: true,
    # NOTE: blessed's `mouse: true` is not a Crysterm constructor kwarg; dropped.
    label: " {blue-fg}Form{/blue-fg} ",
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

  submit.on(Crysterm::Event::Press) do
    # NOTE: blessed had a buggy `tabs.send._.form.submit()` here; the intent is
    # to submit the enclosing form.
    form.submit
  end

  form.on(Crysterm::Event::SubmitData) do |e|
    # NOTE: blessed left the screen and console.log'd the data; here we just
    # collect (no-op) and destroy.
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
