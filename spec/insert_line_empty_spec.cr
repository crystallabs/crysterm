require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `Widget#insert_line` (and its `prepend_line`/`insert_top` callers) must not
# raise on a freshly built widget. Empty content leaves `@_clines.ftor` empty,
# and the old `ftor[@_clines.ftor.size - 1]` became `ftor[-1]`, raising
# `IndexError`. Mirrors the empty-content guard already proven for `#line`.
describe "Widget#insert_line on empty content" do
  it "prepend_line into a freshly built widget does not raise" do
    box = Widget::Box.new parent: headless_screen
    box.prepend_line "hello"
    box.line(0).should eq "hello"
  end

  it "insert_line(0, ...) into a freshly built widget does not raise" do
    box = Widget::Box.new parent: headless_screen
    box.insert_line 0, "first"
    box.lines.should eq ["first"]
  end

  it "insert_line(...) (append) on empty content does not raise" do
    box = Widget::Box.new parent: headless_screen
    box.insert_line "tail"
    box.line(0).should eq "tail"
  end

  it "insert_top on empty content does not raise" do
    box = Widget::Box.new parent: headless_screen
    box.insert_top "top"
    box.line(0).should eq "top"
  end

  it "still inserts correctly once content exists" do
    box = Widget::Box.new parent: headless_screen
    box.set_content "one\ntwo"
    box.insert_line 1, "mid"
    box.lines.should eq ["one", "mid", "two"]
    box.prepend_line "zero"
    box.lines.first.should eq "zero"
  end
end
