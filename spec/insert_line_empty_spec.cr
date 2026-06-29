require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `Widget#insert_line` (and its `unshift_line`/`insert_top` callers) must not
# raise on a freshly built widget. Empty content leaves `@_clines.ftor` empty
# (a brand-new widget, or content cleared with `set_content ""`, never wraps),
# and the old `ftor[@_clines.ftor.size - 1]` was `ftor[-1]`, which raised
# `IndexError`. Mirrors the empty-content guard already proven for `#get_line`.
describe "Widget#insert_line on empty content" do
  it "unshift_line into a freshly built widget does not raise" do
    box = Widget::Box.new parent: headless_screen
    box.unshift_line "hello"
    box.get_line(0).should eq "hello"
  end

  it "insert_line(0, ...) into a freshly built widget does not raise" do
    box = Widget::Box.new parent: headless_screen
    box.insert_line 0, "first"
    box.get_lines.should eq ["first"]
  end

  it "insert_line(nil, ...) (append) on empty content does not raise" do
    box = Widget::Box.new parent: headless_screen
    box.insert_line nil, "tail"
    box.get_line(0).should eq "tail"
  end

  it "insert_top on empty content does not raise" do
    box = Widget::Box.new parent: headless_screen
    box.insert_top "top"
    box.get_line(0).should eq "top"
  end

  it "still inserts correctly once content exists" do
    box = Widget::Box.new parent: headless_screen
    box.set_content "one\ntwo"
    box.insert_line 1, "mid"
    box.get_lines.should eq ["one", "mid", "two"]
    box.unshift_line "zero"
    box.get_lines.first.should eq "zero"
  end
end
