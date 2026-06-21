require "./spec_helper"

include Crysterm

# `Widget::Marquee` scroll logic, driven headlessly over in-memory IOs so no real
# terminal is touched. `#step` is pure (it only recomposes `content`; it does not
# render or sleep), so it can be exercised directly without the animation fiber.

private def marquee_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::Marquee do
  it "renders an awidth-wide window onto the looping message" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 10, height: 1, text: "ABCDE"
    w = m.awidth

    m.step
    m.content.should eq String.build { |io| (0...w).each { |x| io << "ABCDE"[x % 5] } }
  end

  it "scrolls right-to-left: one column per step" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 10, height: 1, text: "ABCDE"
    w = m.awidth

    m.step # frame 0
    m.step # frame 1 — window has shifted left by one column
    m.content.should eq String.build { |io| (0...w).each { |x| io << "ABCDE"[(1 + x) % 5] } }
  end

  it "scrolls left-to-right in :right direction" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 10, height: 1,
      text: "ABCDE", direction: :right
    w = m.awidth

    m.step # frame 0 — column x shows text[-x], using sign-safe modulo
    m.content.should eq String.build { |io| (0...w).each { |x| io << "ABCDE"[((0 - x) % 5)] } }
  end

  it "loops seamlessly through trailing-space gaps" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 4, height: 1, text: "AB  "
    w = m.awidth

    # Over text.size steps the window returns to its starting frame.
    first = (m.step; m.content)
    m.text.size.times { m.step }
    m.content.should eq first
    w.should be > 0
  end

  it "tints each non-space glyph when rainbow is on" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 6, height: 1,
      text: "AB", rainbow: true
    m.step
    # Rainbow output carries per-glyph `{#rrggbb-fg}` tags and closing `{/}`.
    m.content.should contain "-fg}"
    m.content.should contain "{/}"
  end

  it "leaves spaces untinted under rainbow" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 4, height: 1,
      text: "    ", rainbow: true
    m.step
    # All spaces → no color tags emitted at all.
    m.content.should_not contain "-fg}"
  end
end
