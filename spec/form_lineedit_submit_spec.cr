require "./spec_helper"

include Crysterm

# `Form` collects field values through `Mixin::TextEditing`, not `PlainTextEdit`
# alone. `LineEdit` is a *sibling* of `PlainTextEdit` (derives `Input`, while
# `PlainTextEdit` derives `AbstractScrollArea`); they only share the text buffer
# via the mixin. Keying `#field_value`/`#reset_children` off `PlainTextEdit`
# therefore silently dropped `LineEdit` fields on submit/reset.

describe Crysterm::Widget::Form do
  it "#submit collects a LineEdit field's value" do
    s = headless_screen(default_quit_keys: true)
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    Crysterm::Widget::LineEdit.new(parent: form, name: "name", top: 0, height: 1, content: "Alice")

    form.submit
    data = form.submission.not_nil!
    data["name"]?.should eq "Alice"
  end

  it "#reset clears a LineEdit field" do
    s = headless_screen(default_quit_keys: true)
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    le = Crysterm::Widget::LineEdit.new(parent: form, name: "name", top: 0, height: 1, content: "Alice")

    form.reset
    le.value.should eq ""
  end
end
