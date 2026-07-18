require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 #1: `Direct#print`/`#newline` bypassed Tput's
# shadow cursor, so a following relative move clamped against a stale position
# and emitted the wrong (often zero-parameter, which terminals treat as 1)
# CUB/CUU distance. Also locks the related tput fix: a zero delta in
# CUU/CUD/CUF/CUB emits nothing at all instead of `\e[0A`-style sequences.
#
# Unstyled prints emit no SGR escapes, so the in-memory output is byte-exact.

private def direct_io
  mem = IO::Memory.new
  d = Crysterm::Direct.new(
    input: IO::Memory.new,
    output: mem,
    error: IO::Memory.new,
  )
  {d, mem}
end

describe "BUGS15 1: Direct print/newline keep Tput's shadow cursor in sync" do
  it "print advances the shadow so a relative move returns to the start" do
    d, mem = direct_io
    d.move_to 0, 0
    d.print "Working"
    d.tput.cursor.x.should eq 7
    mem.clear
    d.move_by dx: -7 # back to column 0
    mem.to_s.should eq "\e[7D"
    d.tput.cursor.x.should eq 0
  end

  it "print advances by display width for wide glyphs" do
    d, _ = direct_io
    d.move_to 0, 0
    d.print "日本"
    d.tput.cursor.x.should eq 4
  end

  it "print clamps the shadow at the last column (auto-wrap not modeled)" do
    d, _ = direct_io
    d.move_to 0, d.width - 3
    d.print "abcdef"
    d.tput.cursor.x.should eq d.width - 1
  end

  it "newline moves the shadow to column 0 of the next rows" do
    d, mem = direct_io
    d.move_to 0, 5
    d.newline 3
    d.tput.cursor.x.should eq 0
    d.tput.cursor.y.should eq 3
    mem.clear
    d.cursor_up 3
    mem.to_s.should eq "\e[3A"
  end

  it "newline pins the shadow to the last row once the terminal scrolls" do
    d, _ = direct_io
    d.move_to d.height - 2, 5
    d.newline 5
    d.tput.cursor.x.should eq 0
    d.tput.cursor.y.should eq d.height - 1
  end

  it "vline emits real 1-column returns, not zero-parameter CUB" do
    d, mem = direct_io
    d.move_to 0, 0
    d.vline 2, '|'
    s = mem.to_s
    s.should contain "\e[1D"
    s.should_not contain "\e[0D"
  end

  it "a clamped-to-zero relative move emits nothing (no \\e[0A ghost step)" do
    d, mem = direct_io
    d.move_to 0, 0
    mem.clear
    d.cursor_up 5 # already on row 0: clamp reduces the delta to 0
    d.cursor_left 3
    mem.to_s.should eq ""
  end

  it "a zero-delta axis in move_by emits nothing" do
    d, mem = direct_io
    d.move_to 2, 2
    mem.clear
    d.move_by dy: 0, dx: 1 # dy leg must stay silent
    mem.to_s.should eq "\e[1C"
  end
end
