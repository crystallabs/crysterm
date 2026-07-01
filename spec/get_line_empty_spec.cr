require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `Widget#get_line` / `#get_baseline` (Blessed `getLine` parity) must not raise
# on empty content: empty content leaves `@_clines.fake` empty, and Crystal's
# `clamp(0, -1)` returns -1, so the old `fake[-1]` raised `IndexError`.
describe "Widget#get_line on empty content" do
  it "returns a blank line instead of raising on a freshly built widget" do
    box = Widget::Box.new parent: headless_screen
    box.get_line(0).should eq ""
    box.get_line(5).should eq ""
  end

  it "returns a blank line after content is cleared to empty" do
    box = Widget::Box.new parent: headless_screen, content: "hello"
    box.set_content ""
    box.get_line(0).should eq ""
  end

  it "get_baseline is guarded too" do
    box = Widget::Box.new parent: headless_screen
    box.get_baseline(0).should eq ""
  end

  it "still returns real lines for non-empty content" do
    box = Widget::Box.new parent: headless_screen
    box.set_content "one\ntwo"
    box.get_line(0).should eq "one"
    box.get_line(1).should eq "two"
    # Out-of-range index clamps to the last line rather than raising.
    box.get_line(99).should eq "two"
  end
end
