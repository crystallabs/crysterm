require "./spec_helper"

# `Widgets` is a namespace of aliases onto the real `Widget::*` classes (the
# documented `include Widgets; Text.new` shortcut). A typo on the right-hand
# side (e.g. `Widget::Checkbox` for `Widget::CheckBox`) compiles silently,
# since Crystal only evaluates a constant when first referenced, and only
# fails as `undefined constant` when a user reaches for the shortcut.
# Referencing the aliases here forces resolution at compile time.
describe Crysterm::Widgets do
  it "exposes the checkable-button aliases as the real Widget classes" do
    Crysterm::Widgets::CheckBox.should eq Crysterm::Widget::CheckBox
    Crysterm::Widgets::RadioButton.should eq Crysterm::Widget::RadioButton
    Crysterm::Widgets::Button.should eq Crysterm::Widget::Button
  end

  it "can construct a widget through the convenience alias" do
    s = Crysterm::Window.new(
      input: IO::Memory.new,
      output: IO::Memory.new,
      error: IO::Memory.new,
      width: 80,
      height: 24)
    box = Crysterm::Widgets::CheckBox.new parent: s
    box.should be_a Crysterm::Widget::CheckBox
  end
end
