require "./spec_helper"

include Crysterm

private def hscreen(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# BUGS9 #1 — `ProgressBar#maximum=` discarded a new maximum below the current
# minimum. It called `set_range(@minimum, v)`, whose inverted-range guard
# (`max = min if max < min`) then pulled the maximum back *up* to `@minimum`,
# throwing `v` away entirely — so `bar.maximum = 5` on a bar with `minimum ==
# 10` left the range at `[10, 10]`. Qt's `setMaximum` is
# `setRange(qMin(minimum, maximum), maximum)`: the new maximum wins, pulling the
# minimum down to `[5, 5]`. It was also asymmetric with `#minimum=`, which
# already honored its bound.
describe "BUGS9 ProgressBar#maximum= honors a maximum below the minimum" do
  it "pulls the minimum down so the new maximum wins (Qt setMaximum)" do
    s = hscreen
    bar = Widget::ProgressBar.new parent: s, width: 20, height: 1, minimum: 10, maximum: 100
    bar.maximum = 5
    bar.maximum.should eq 5 # was 100 before the fix (v silently discarded)
    bar.minimum.should eq 5 # dragged down with it, per Qt
  end

  it "still lowers the maximum normally when it stays above the minimum" do
    s = hscreen
    bar = Widget::ProgressBar.new parent: s, width: 20, height: 1, minimum: 0, maximum: 100
    bar.maximum = 40
    bar.maximum.should eq 40
    bar.minimum.should eq 0 # untouched: no inversion, so nothing to drag down
  end

  it "stays symmetric with #minimum= (which already honored its bound)" do
    s = hscreen
    bar = Widget::ProgressBar.new parent: s, width: 20, height: 1, minimum: 0, maximum: 100
    bar.minimum = 150 # above the max -> both collapse to 150
    bar.minimum.should eq 150
    bar.maximum.should eq 150
  end
end

# BUGS9 #2 — `needs_cluster?` (widget_content.cr) is the renderer's exclusive
# gate for grapheme-cluster assembly (widget_rendering.cr): when it returns
# false the base char is laid into a lone cell and `extend_grapheme` never runs.
# Its fast-reject compared the successor against U+200D (ZWJ), but combining
# marks — the lowest cluster extender (`Char#mark?`) — begin at U+0300, far
# below U+200D. So a base like 'e' followed by U+0301 (NFD "é") was wrongly
# rejected and rendered as two detached cells instead of one combined cluster.
describe "BUGS9 needs_cluster? accepts base + combining-mark clusters" do
  it "returns true for a letter followed by a combining mark (NFD e + U+0301)" do
    s = hscreen
    w = Widget::Box.new parent: s, width: 10, height: 1
    w.needs_cluster?('e', '́').should be_true # was false before the fix
  end

  it "still fast-rejects the plain two-ASCII-char case (no regression)" do
    s = hscreen
    w = Widget::Box.new parent: s, width: 10, height: 1
    w.needs_cluster?('a', 'b').should be_false
    w.needs_cluster?('a', nil).should be_false
  end

  it "still accepts the higher-codepoint extenders (ZWJ / skin tone) (no regression)" do
    s = hscreen
    w = Widget::Box.new parent: s, width: 10, height: 1
    w.needs_cluster?('a', '‍').should be_true                 # ZWJ
    w.needs_cluster?('\u{1F44D}', '\u{1F3FB}').should be_true # thumbs-up + skin tone
  end
end
