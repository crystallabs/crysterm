require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# Behavior lock for the region writers after `fill_region`/`blend_region` were
# routed through the shared `each_region_cell` helper. The two differ only in
# whether they clamp a negative origin to 0 (`fill` clamps; `blend` does not).
describe "Screen#fill_region / #blend_region" do
  it "fills the half-open region and marks the line dirty" do
    s = headless_screen
    s.fill_region 7_i64, 'X', 1, 4, 0, 1, override: true

    s.lines[0][0].char.should eq ' ' # left of region, untouched
    s.lines[0][1].char.should eq 'X'
    s.lines[0][3].char.should eq 'X'
    s.lines[0][4].char.should eq ' ' # xl is exclusive
    s.lines[0][1].attr.should eq 7_i64
    s.lines[0].dirty.should be_true
  end

  it "clamps a negative origin to 0 (fill_region)" do
    s = headless_screen
    s.fill_region 5_i64, 'Y', -3, 2, 0, 1, override: true
    # Clamped: only columns 0 and 1 are written, with no wrap to the far edge.
    s.lines[0][0].char.should eq 'Y'
    s.lines[0][1].char.should eq 'Y'
    s.lines[0][2].char.should eq ' '
    s.lines[0][s.awidth - 1].char.should eq ' '
  end

  it "blends existing cell attributes toward black" do
    s = headless_screen
    s.fill_region 0x00FF00_i64, 'a', 0, 2, 0, 1, override: true
    before = s.lines[0][0].attr

    s.blend_region 0.5, 0, 2, 0, 1
    s.lines[0][0].attr.should eq Colors.blend(before, alpha: 0.5)
    s.lines[0][0].char.should eq 'a' # blend only touches the attribute
  end
end

# The inline SGR emission in the draw loop relies on `sgr_params_to`'s return
# value to decide whether to back over a trailing ';' before the terminating
# 'm'. Lock that contract: nothing written (and false) for the all-default attr,
# something written (and true) otherwise.
describe "Screen.sgr_params_to" do
  it "writes nothing and returns false for the default attribute" do
    io = IO::Memory.new
    wrote = Crysterm::Screen.sgr_params_to io, Crysterm::Screen::DEFAULT_ATTR, 256
    wrote.should be_false
    io.size.should eq 0
  end

  it "writes ';'-terminated params and returns true when there is styling" do
    io = IO::Memory.new
    code = Attr.pack Attr::BOLD, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT
    wrote = Crysterm::Screen.sgr_params_to io, code, 256
    wrote.should be_true
    io.to_s.should end_with(";")
  end
end
