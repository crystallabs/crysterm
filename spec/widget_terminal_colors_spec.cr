require "./spec_helper"

include Crysterm

# Colour/attribute regression for the full emulator → `Widget::Terminal` →
# `Window#dump` pipeline.
#
# The `TerminalEmulator` specs prove the parser packs the right attribute onto
# each cell; these prove those attributes survive the widget's grid copy and
# surface correctly in `Window#dump`'s `attrs:` section (`fg/bg+flags` per run).
# That is the CI-safe stand-in for vttest's ISO-6429 colour tests (menu 11.6),
# which need the external `vttest` binary to run live (see `tools/vttest.cr
# --dump`): here the same colour paths are exercised with fixed byte sequences,
# no child process.

# Feeds `data` to an externally-driven Terminal on a headless window and returns
# the resulting `Window#dump`. `handler:` means the widget spawns no PTY/child —
# bytes written go straight into the emulator, keeping the test hermetic.
private def term_dump(data : String, w = 12, h = 2) : String
  window = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, full_unicode: true)
  term = Crysterm::Widget::Terminal.new(
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    handler: ->(_s : String) { })
  window.repaint # bootstrap: sizes and attaches the emulator
  term.write data
  window.repaint # copy the emulator grid (incl. attrs) onto the window cells
  window.dump.to_s
end

# The `attrs:` run-list for row `y` (e.g. "y0: 0-1:#cd0000/#0000ee"), or "" when
# the row is entirely the screen default (such rows are omitted from the dump).
private def attrs_row(dump : String, y : Int32) : String
  dump.each_line.find(&.starts_with?("y#{y}:")).to_s.strip
end

describe "Widget::Terminal colour / attributes via Window#dump" do
  it "renders an SGR 16-colour foreground/background pair" do
    # `CSI 31;44 m` — red on blue.
    attrs_row(term_dump("\e[31;44mHi"), 0).should eq "y0: 0-1:#cd0000/#0000ee"
  end

  it "returns to the screen default after SGR 0 (reset)" do
    # Only 'Hi' is coloured; 'ok' reverts to default fg/bg and is omitted from
    # the attrs list — asserting the run stays exactly the two coloured cells.
    attrs_row(term_dump("\e[31;44mHi\e[0mok"), 0).should eq "y0: 0-1:#cd0000/#0000ee"
  end

  it "carries the bold flag (vttest's 'bright' colours)" do
    attrs_row(term_dump("\e[1;31mB"), 0).should eq "y0: 0-0:#cd0000/def+b"
  end

  it "renders a 256-colour foreground (SGR 38;5)" do
    attrs_row(term_dump("\e[38;5;196mX"), 0).should eq "y0: 0-0:#ff0000/def"
  end

  it "renders a truecolour foreground (SGR 38;2)" do
    # 10;20;30 → #0a141e.
    attrs_row(term_dump("\e[38;2;10;20;30mT"), 0).should eq "y0: 0-0:#0a141e/def"
  end

  it "applies background-colour erase (BCE) to cleared cells" do
    # Set a red background, then erase the whole line: the blanked cells must
    # take the *current* background (ISO-6429 BCE), so the run spans the width.
    attrs_row(term_dump("\e[41m\e[2K", 12, 2), 0).should eq "y0: 0-11:def/#cd0000"
  end
end
