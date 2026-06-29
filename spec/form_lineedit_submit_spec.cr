require "./spec_helper"

include Crysterm

# A `Form` collects its fields' values through `Mixin::TextEditing`, not through
# `PlainTextEdit` alone. `LineEdit` is a *sibling* of `PlainTextEdit` (it derives
# `Input`, while `PlainTextEdit` derives `AbstractScrollArea`); the two only share
# the text buffer via the mixin. Keying `#field_value`/`#reset_children` off
# `PlainTextEdit` therefore silently dropped every `LineEdit` field on submit and
# never cleared it on reset — yet a single-line text field is the form's primary
# use case (see the `Widget::Form` class docs).
#
# Driven headlessly over in-memory IOs.

private def form_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::Form do
  it "#submit collects a LineEdit field's value" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    Crysterm::Widget::LineEdit.new(parent: form, name: "name", top: 0, height: 1, content: "Alice")

    form.submit
    data = form.submission.not_nil!
    data["name"]?.should eq "Alice"
  end

  it "#reset clears a LineEdit field" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    le = Crysterm::Widget::LineEdit.new(parent: form, name: "name", top: 0, height: 1, content: "Alice")

    form.reset
    le.value.should eq ""
  end
end
