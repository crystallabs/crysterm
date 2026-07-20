require "./spec_helper"

# WP-13 [S] — text-first positional constructor overloads on leaf widgets,
# so examples can read `Button.new("Submit", parent: form)` like Qt's
# `QPushButton("Submit", parent)`. Covers Button, CheckBox, RadioButton,
# Label and LineEdit; GroupBox already had an untyped positional `title`
# param and needed no change.

private def wp13_window(width = 40, height = 15)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

describe "WP-13 text-first positional constructors" do
  it "Button.new(text) sets the label; explicit content: still wins" do
    s = wp13_window
    b = Crysterm::Widget::Button.new "Submit", parent: s
    b.text.should eq "Submit"
    b.content.should eq "Submit"

    b2 = Crysterm::Widget::Button.new "Submit", content: "Override", parent: s
    b2.text.should eq "Override"
  ensure
    s.try &.destroy
  end

  it "CheckBox.new(text) sets the label via the marker content path" do
    s = wp13_window
    c = Crysterm::Widget::CheckBox.new "Wrap", parent: s
    c.text.should eq "Wrap"

    c2 = Crysterm::Widget::CheckBox.new "Wrap", content: "Override", parent: s
    c2.text.should eq "Override"
  ensure
    s.try &.destroy
  end

  it "RadioButton.new(text) sets the label via the marker content path" do
    s = wp13_window
    r = Crysterm::Widget::RadioButton.new "Option A", parent: s
    r.text.should eq "Option A"

    r2 = Crysterm::Widget::RadioButton.new "Option A", content: "Override", parent: s
    r2.text.should eq "Override"
  ensure
    s.try &.destroy
  end

  it "Label.new(text) sets the label; keyword-only construction still works" do
    s = wp13_window
    l = Crysterm::Widget::Label.new "Hello", parent: s
    l.text.should eq "Hello"

    l2 = Crysterm::Widget::Label.new content: "Direct", parent: s
    l2.text.should eq "Direct"

    l3 = Crysterm::Widget::Label.new "Hello", content: "Override", parent: s
    l3.text.should eq "Override"
  ensure
    s.try &.destroy
  end

  it "LineEdit.new(contents) sets the initial value; explicit content: still wins" do
    s = wp13_window
    le = Crysterm::Widget::LineEdit.new "seed", parent: s
    le.value.should eq "seed"

    le2 = Crysterm::Widget::LineEdit.new "seed", content: "override", parent: s
    le2.value.should eq "override"
  ensure
    s.try &.destroy
  end

  it "GroupBox already accepts a positional title (untyped param, pre-existing)" do
    s = wp13_window
    gb = Crysterm::Widget::GroupBox.new "Options", parent: s
    gb.title.should eq "Options"
  ensure
    s.try &.destroy
  end
end
