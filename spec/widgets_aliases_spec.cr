require "./spec_helper"

# The `Widgets` module is a convenience namespace of aliases onto the real
# `Widget::*` classes (the documented `include Widgets; Text.new` shortcut).
# Each alias must point at a class that actually exists: a typo on the
# right-hand side (e.g. `Widget::Checkbox` for the real `Widget::CheckBox`)
# compiles silently — Crystal only evaluates an unused constant when it is first
# referenced — and only blows up as `undefined constant` the moment a user
# reaches for the shortcut. Referencing the aliases here forces that resolution
# at compile time, so a broken alias fails the build instead of an app.
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
