require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `Widget#delete_line` deletes via `n.times { fake.delete_at i }` with a fixed
# `i`. It clamped `i` but not `n`, so deleting more lines than remain from `i`
# (`pop_line 2`, `shift_line n` past the count, `delete_line(i, n)` with
# `i + n > fake.size`) ran `delete_at` off the end and raised `IndexError`.
# `n` is now clamped, like JS `splice(i, n)`.
describe "Widget#delete_line over-count" do
  it "pop_line n past the end does not raise" do
    # `pop_line(n)` is `delete_line(fake.size - 1, n)`, a *forward* delete from
    # the last index (Blessed `splice` semantics); it removes only the last
    # line regardless of `n`, but the over-count used to raise first.
    box = Widget::Box.new parent: headless_screen
    box.set_content "one\ntwo\nthree"
    box.pop_line 2
    box.get_lines.should eq ["one", "two"]
  end

  it "shift_line n past the end clears all lines without raising" do
    box = Widget::Box.new parent: headless_screen
    box.set_content "one\ntwo\nthree"
    box.shift_line 10
    box.get_lines.should eq [] of String
  end

  it "delete_line(i, n) with i + n beyond the end deletes only what remains" do
    box = Widget::Box.new parent: headless_screen
    box.set_content "a\nb\nc\nd"
    box.delete_line 2, 9
    box.get_lines.should eq ["a", "b"]
  end

  it "an exact-count delete still removes precisely n lines" do
    box = Widget::Box.new parent: headless_screen
    box.set_content "a\nb\nc\nd"
    box.delete_line 1, 2
    box.get_lines.should eq ["a", "d"]
  end
end
