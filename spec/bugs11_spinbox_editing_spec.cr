require "./spec_helper"

include Crysterm

# BUGS11 #17 — `Mixin::SpinBoxEditing#handle_key_press` accepted Enter and Escape
# UNCONDITIONALLY, even with no edit in progress (`@editing` nil, so
# `commit_edit`/`cancel_edit` are no-ops). An accepted event starves
# window-level dialog accelerators — `Widget::Dialog` does
# `return if e.accepted?` — so a focused SpinBox in a Dialog swallowed Enter and
# Escape, and the dialog could not be confirmed/cancelled from the keyboard.
#
# The Enter and Escape arms are gated on `editing?`: with no edit buffer the
# key falls through un-accepted so the accelerators still fire; with an edit in
# progress, Enter commits and Escape cancels, both accepting the event.

private def bugs11_keypress(ch : Char, key : Tput::Key? = nil)
  Crysterm::Event::KeyPress.new ch, key
end

describe "BUGS11 #17 SpinBox does not starve dialog accelerators" do
  it "does NOT accept Escape when there is no edit in progress" do
    s = headless_screen(80, 24)
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
    sb.editing?.should be_false

    e = bugs11_keypress('\e', Tput::Key::Escape)
    sb.handle_key_press e
    # Un-accepted so a Dialog's window-level accelerator would still fire.
    e.accepted?.should be_false
  end

  it "does NOT accept Enter when there is no edit in progress" do
    s = headless_screen(80, 24)
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
    sb.editing?.should be_false

    e = bugs11_keypress('\r', Tput::Key::Enter)
    sb.handle_key_press e
    e.accepted?.should be_false
  end

  it "DOES accept Escape while editing and cancels the edit" do
    s = headless_screen(80, 24)
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
    sb.handle_key_press bugs11_keypress('4') # start editing
    sb.handle_key_press bugs11_keypress('2')
    sb.editing?.should be_true

    e = bugs11_keypress('\e', Tput::Key::Escape)
    sb.handle_key_press e
    e.accepted?.should be_true
    sb.editing?.should be_false
    sb.value.should eq 10 # cancel restores committed value
  end

  it "DOES accept Enter while editing and commits the edit" do
    s = headless_screen(80, 24)
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
    sb.handle_key_press bugs11_keypress('4')
    sb.handle_key_press bugs11_keypress('2')
    sb.editing?.should be_true

    e = bugs11_keypress('\r', Tput::Key::Enter)
    sb.handle_key_press e
    e.accepted?.should be_true
    sb.editing?.should be_false
    sb.value.should eq 42 # committed the typed buffer
  end
end

describe "BUGS11 #17 DoubleSpinBox does not starve dialog accelerators" do
  it "does NOT accept Escape when there is no edit in progress" do
    s = headless_screen(80, 24)
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 10.0
    d.editing?.should be_false

    e = bugs11_keypress('\e', Tput::Key::Escape)
    d.handle_key_press e
    e.accepted?.should be_false
  end

  it "DOES accept Enter while editing and commits the edit" do
    s = headless_screen(80, 24)
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 10.0
    d.handle_key_press bugs11_keypress('4')
    d.handle_key_press bugs11_keypress('2')
    d.editing?.should be_true

    e = bugs11_keypress('\r', Tput::Key::Enter)
    d.handle_key_press e
    e.accepted?.should be_true
    d.editing?.should be_false
    d.value.should eq 42.0
  end
end
