require "./spec_helper"

include Crysterm

private def fu_window(width = 20, height = 4)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  s
end

describe "Widget#scroll_height between frames" do
  it "follows a child added after the last render" do
    s = headless_screen(40, 12)
    box = Widget.new parent: s, top: 0, left: 0, width: 20, height: 5,
      scrollable: true
    Widget.new parent: box, top: 2, left: 0, width: 10, height: 2
    s.repaint
    box.scroll_height.should eq 4

    Widget.new parent: box, top: 20, left: 0, width: 10, height: 1
    box.scroll_height.should eq 21
  end

  it "follows a child moved or removed after the last render" do
    s = headless_screen(40, 12)
    box = Widget.new parent: s, top: 0, left: 0, width: 20, height: 5,
      scrollable: true
    Widget.new parent: box, top: 2, left: 0, width: 10, height: 2
    deep = Widget.new parent: box, top: 20, left: 0, width: 10, height: 1
    s.repaint
    box.scroll_height.should eq 21

    deep.top = 30
    box.scroll_height.should eq 31

    box.remove deep
    box.scroll_height.should eq 4
  end
end

describe "Widget content control characters" do
  it "strips C1 controls like the C0 ones" do
    s = headless_screen(40, 6)
    w = Widget.new parent: s, top: 0, left: 0, width: 20, height: 1,
      content: "a\u{9b}31mb\u{85}c"
    w.rendered_content.should eq "a31mbc"
  end
end

describe "Widget rendering of zero-width codepoints (full_unicode)" do
  it "gives a lone zero-width codepoint no cell of its own" do
    s = fu_window
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    w = Widget.new parent: s, top: 0, left: 0, width: 10, height: 1,
      content: "a\u{200b}b"
    s.repaint

    ox, oy = w.painted_content_origin
    row = s.cell_rows[oy]
    row[ox].grapheme.should eq "a\u{200b}"
    row[ox + 1].char.should eq 'b'
  end

  it "merges conjoining jamo into the wide lead cell, keeping its continuation" do
    s = fu_window
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    w = Widget.new parent: s, top: 0, left: 0, width: 10, height: 1,
      content: "\u{1112}\u{1161}\u{11ab}b"
    s.repaint

    ox, oy = w.painted_content_origin
    row = s.cell_rows[oy]
    row[ox].grapheme.should eq "\u{1112}\u{1161}\u{11ab}"
    row[ox + 1].continuation?.should be_true
    row[ox + 2].char.should eq 'b'
  end
end
