require "./spec_helper"

include Crysterm

private def bcv_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `#value` is documented as the mirror of `#checked?` for a checkable control,
# so a checkable Button constructed pre-checked must report value == true — not
# the default false left when only @checked was seeded at construction.
describe Crysterm::Widget::Button do
  it "mirrors checked? into value when constructed pre-checked" do
    s = bcv_window
    b = Crysterm::Widget::Button.new parent: s, checkable: true, checked: true, content: "B"
    b.checked?.should be_true
    b.value.should be_true
  end

  it "leaves value false for an unchecked (or push) button" do
    s = bcv_window
    b = Crysterm::Widget::Button.new parent: s, checkable: true, checked: false, content: "B"
    b.checked?.should be_false
    b.value.should be_false

    push = Crysterm::Widget::Button.new parent: s, content: "P"
    push.value.should be_false
  end

  it "keeps value mirroring checked? across toggles" do
    s = bcv_window
    b = Crysterm::Widget::Button.new parent: s, checkable: true, checked: true, content: "B"
    b.toggle
    b.checked?.should be_false
    b.value.should be_false
    b.toggle
    b.checked?.should be_true
    b.value.should be_true
  end
end
