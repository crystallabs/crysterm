require "./spec_helper"

include Crysterm

# BUGS9 #1 — `ProgressBar#maximum=` must not discard a new maximum below the
# current minimum. Calling `set_range(@minimum, v)` lets the inverted-range
# guard (`max = min if max < min`) pull the maximum back *up* to `@minimum`,
# throwing `v` away entirely — `bar.maximum = 5` on a bar with `minimum == 10`
# leaves the range at `[10, 10]`. Qt's `setMaximum` is
# `setRange(qMin(minimum, maximum), maximum)`: the new maximum wins, pulling the
# minimum down to `[5, 5]` — and symmetric with `#minimum=`, which already
# honors its bound.
describe "BUGS9 ProgressBar#maximum= honors a maximum below the minimum" do
  it "pulls the minimum down so the new maximum wins (Qt setMaximum)" do
    s = headless_screen(40, 20)
    bar = Widget::ProgressBar.new parent: s, width: 20, height: 1, minimum: 10, maximum: 100
    bar.maximum = 5
    bar.maximum.should eq 5 # not silently discarded
    bar.minimum.should eq 5 # dragged down with it, per Qt
  end

  it "still lowers the maximum normally when it stays above the minimum" do
    s = headless_screen(40, 20)
    bar = Widget::ProgressBar.new parent: s, width: 20, height: 1, minimum: 0, maximum: 100
    bar.maximum = 40
    bar.maximum.should eq 40
    bar.minimum.should eq 0 # untouched: no inversion, so nothing to drag down
  end

  it "stays symmetric with #minimum= (which already honored its bound)" do
    s = headless_screen(40, 20)
    bar = Widget::ProgressBar.new parent: s, width: 20, height: 1, minimum: 0, maximum: 100
    bar.minimum = 150 # above the max -> both collapse to 150
    bar.minimum.should eq 150
    bar.maximum.should eq 150
  end
end

# BUGS9 #2 — `needs_cluster?` (widget_content.cr) is the renderer's exclusive
# gate for grapheme-cluster assembly (widget_rendering.cr): when it returns
# false the base char is laid into a lone cell and `extend_grapheme` never runs.
# A fast-reject comparing the successor against U+200D (ZWJ) misses combining
# marks — the lowest cluster extenders (`Char#mark?`) begin at U+0300, far
# below U+200D — so a base like 'e' followed by U+0301 (NFD "é") is wrongly
# rejected and renders as two detached cells instead of one combined cluster.
describe "BUGS9 needs_cluster? accepts base + combining-mark clusters" do
  it "returns true for a letter followed by a combining mark (NFD e + U+0301)" do
    s = headless_screen(40, 20)
    w = Widget::Box.new parent: s, width: 10, height: 1
    w.needs_cluster?('e', '́').should be_true
  end

  it "still fast-rejects the plain two-ASCII-char case (no regression)" do
    s = headless_screen(40, 20)
    w = Widget::Box.new parent: s, width: 10, height: 1
    w.needs_cluster?('a', 'b').should be_false
    w.needs_cluster?('a', nil).should be_false
  end

  it "still accepts the higher-codepoint extenders (ZWJ / skin tone) (no regression)" do
    s = headless_screen(40, 20)
    w = Widget::Box.new parent: s, width: 10, height: 1
    w.needs_cluster?('a', '‍').should be_true                 # ZWJ
    w.needs_cluster?('\u{1F44D}', '\u{1F3FB}').should be_true # thumbs-up + skin tone
  end
end
