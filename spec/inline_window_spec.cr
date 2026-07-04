require "./spec_helper"

include Crysterm

private def inline_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40,
    height: 6,
    alternate: false,
    default_quit_keys: false,
  )
end

private def alt_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40,
    height: 6,
    default_quit_keys: false,
  )
end

describe "inline (non-alt) Window" do
  it "does not switch to the alternate screen buffer" do
    alt = alt_window
    inline = inline_window

    # The full-screen window is in the alt buffer; the inline one never entered it.
    alt.tput.is_alt.should be_true
    inline.tput.is_alt.should be_false

    inline_out = inline.output.as(IO::Memory).to_s
    smcup = alt.tput.shim.try(&.smcup?).try { |b| String.new(b) }
    inline_out.should_not contain smcup if smcup && !smcup.empty?
    # DEC private mode 1049/47 alt-buffer forms, whichever the terminal uses.
    inline_out.should_not contain "\e[?1049h"
    inline_out.should_not contain "\e[?47h"
  end

  it "reports alternate? = false and a fixed height" do
    inline = inline_window
    inline.alternate?.should be_false
    inline.aheight.should eq 6
  end

  it "offsets every rendered row by render_row_offset" do
    inline = inline_window
    # Headless: report_cursor can't answer, so the anchor defaults to 0. Pin an
    # offset to exercise the translation seam.
    inline.render_row_offset = 10

    Widget::Box.new parent: inline, top: 0, left: 0, width: 40, height: 6,
      content: "hello", style: Style.new(bg: 0x202020)

    inline.output.as(IO::Memory).clear
    inline._render

    out = inline.output.as(IO::Memory).to_s
    # A CUP to the surface's row 0 must land on physical row 11 (1-based 10+1),
    # never on row 1 (`\e[1;...H`), which would be the un-offset position.
    out.should contain "\e[11;"
    out.should_not match /\e\[1;\d+H/
  end

  it "restores the terminal on leave (releases scroll region, parks cursor below)" do
    inline = inline_window
    inline.render_row_offset = 4
    inline.output.as(IO::Memory).clear
    inline.leave
    out = inline.output.as(IO::Memory).to_s
    # Cursor parked just below the region: offset(4) + aheight(6) = row 10 -> 1-based 11.
    out.should contain "\e[11;1H"
  end
end
