require "./spec_helper"

include Crysterm

# OSC 8 hyperlink emission (TEXTEDIT.md follow-up): anchor runs painted by
# `Widget::TextEdit` carry a cell link id (`Window#link_id` registry), and
# the draw loop brackets them in tput's `begin_hyperlink`/`end_hyperlink`
# escapes — only when a printed cell's link differs from the one in effect,
# and closed before the frame ends.

private def osc8_screen(output = IO::Memory.new, width = 30, height = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
end

private def anchor_te(s, url = "https://x.io")
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 30, height: 4, content: "click here"
  te.document.apply_char_format(0, 5, TextCharFormat.new(anchor_href: url))
  te
end

describe "OSC 8 hyperlinks" do
  it "paints anchor cells with a registered link id" do
    s = osc8_screen
    te = anchor_te(s)
    s._render
    id = s.lines[0][0].link
    id.should_not eq 0
    s.link_url(id).should eq "https://x.io"
    s.lines[0][4].link.should eq id
    # Past the anchor: no link.
    s.lines[0][6].link.should eq 0
  end

  it "emits OSC 8 open around the anchor and closes before the frame ends" do
    outp = IO::Memory.new
    s = osc8_screen(outp)
    anchor_te(s)
    s._render
    text = outp.to_s
    text.should contain "\e]8;;https://x.io\e\\"
    text.should contain "\e]8;;\e\\"
    # The close comes after the open (link never leaks past the frame).
    text.rindex!("\e]8;;\e\\").should be > text.index!("\e]8;;https://x.io\e\\")
  end

  it "does not re-emit an unchanged frame's links" do
    outp = IO::Memory.new
    s = osc8_screen(outp)
    anchor_te(s)
    s._render
    outp.clear
    s._render
    outp.to_s.should_not contain "\e]8;;"
  end

  it "re-emits when the link target changes under an identical glyph" do
    outp = IO::Memory.new
    s = osc8_screen(outp)
    te = anchor_te(s)
    s._render
    outp.clear
    te.document.apply_char_format(0, 5, TextCharFormat.new(anchor_href: "https://y.io"))
    s._render
    outp.to_s.should contain "\e]8;;https://y.io\e\\"
  end

  it "clears the cell link when the anchor is removed" do
    s = osc8_screen
    te = anchor_te(s)
    s._render
    te.document.apply_char_format(0, 5, TextCharFormat.new(bold: true))
    s._render
    s.lines[0][0].link.should eq 0
  end

  it "registers each distinct URL once" do
    s = osc8_screen
    a = s.link_id("https://x.io")
    b = s.link_id("https://x.io")
    c = s.link_id("https://z.io")
    a.should eq b
    c.should_not eq a
    s.link_url(c).should eq "https://z.io"
  end

  it "emits nothing when hyperlinks are disabled" do
    outp = IO::Memory.new
    s = osc8_screen(outp)
    s.hyperlinks = false
    anchor_te(s)
    s._render
    s.lines[0][0].link.should eq 0
    outp.to_s.should_not contain "\e]8;;"
  end
end
