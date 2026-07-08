require "./spec_helper"

include Crysterm

# Regression spec for BUGS11 #17.
#
#  Bug (fixed in src/mixin/spinbox_editing.cr): `Mixin::SpinBoxEditing#on_keypress`
#  accepted Enter and Escape UNCONDITIONALLY, even with no edit in progress
#  (`@editing` nil, so `commit_edit`/`cancel_edit` are no-ops). An accepted event
#  starves window-level dialog accelerators — `Widget::Dialog` does
#  `return if e.accepted?` — so a focused SpinBox in a Dialog swallowed Enter and
#  Escape, and the dialog could not be confirmed/cancelled from the keyboard.
#
#  Fix: gate the Enter and Escape arms on `editing?`. With no edit buffer, the
#  key falls through un-accepted so the accelerators still fire; with an edit in
#  progress, Enter commits and Escape cancels, both accepting the event.

private def bugs11_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def bugs11_keypress(ch : Char, key : Tput::Key? = nil)
  Crysterm::Event::KeyPress.new ch, key
end

describe "BUGS11 #17 SpinBox does not starve dialog accelerators" do
  it "does NOT accept Escape when there is no edit in progress" do
    s = bugs11_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
    sb.editing?.should be_false

    e = bugs11_keypress('\e', Tput::Key::Escape)
    sb.on_keypress e
    # Un-accepted so a Dialog's window-level accelerator would still fire.
    e.accepted?.should be_false
  end

  it "does NOT accept Enter when there is no edit in progress" do
    s = bugs11_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
    sb.editing?.should be_false

    e = bugs11_keypress('\r', Tput::Key::Enter)
    sb.on_keypress e
    e.accepted?.should be_false
  end

  it "DOES accept Escape while editing and cancels the edit" do
    s = bugs11_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
    sb.on_keypress bugs11_keypress('4') # start editing
    sb.on_keypress bugs11_keypress('2')
    sb.editing?.should be_true

    e = bugs11_keypress('\e', Tput::Key::Escape)
    sb.on_keypress e
    e.accepted?.should be_true
    sb.editing?.should be_false
    sb.value.should eq 10 # cancel restores committed value
  end

  it "DOES accept Enter while editing and commits the edit" do
    s = bugs11_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
    sb.on_keypress bugs11_keypress('4')
    sb.on_keypress bugs11_keypress('2')
    sb.editing?.should be_true

    e = bugs11_keypress('\r', Tput::Key::Enter)
    sb.on_keypress e
    e.accepted?.should be_true
    sb.editing?.should be_false
    sb.value.should eq 42 # committed the typed buffer
  end
end

describe "BUGS11 #17 DoubleSpinBox does not starve dialog accelerators" do
  it "does NOT accept Escape when there is no edit in progress" do
    s = bugs11_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 10.0
    d.editing?.should be_false

    e = bugs11_keypress('\e', Tput::Key::Escape)
    d.on_keypress e
    e.accepted?.should be_false
  end

  it "DOES accept Enter while editing and commits the edit" do
    s = bugs11_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 10.0
    d.on_keypress bugs11_keypress('4')
    d.on_keypress bugs11_keypress('2')
    d.editing?.should be_true

    e = bugs11_keypress('\r', Tput::Key::Enter)
    d.on_keypress e
    e.accepted?.should be_true
    d.editing?.should be_false
    d.value.should eq 42.0
  end
end
