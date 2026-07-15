require "./spec_helper"

include Crysterm

# Regression specs for the BUGS9 Layout & Geometry fixes. Headless harness
# mirrors `spec/bugs8_layout_spec.cr` / `spec/bugs6_layout_spec.cr`.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# A shrink-to-content (`shrink_to_fit`) box holding one fixed child, anchored to
# *near* (left/top) or *far* (right/bottom), with the given padding. Returns the
# rendered outer rectangle `{xi, xl, yi, yl}`.
private def shrink_box_rect(anchor : Symbol, pad : Crysterm::Padding, child_w = 6, child_h = 3)
  s = headless_screen
  st = Style.new(padding: pad)
  sh =
    case anchor
    when :left  then Widget::Box.new parent: s, top: 2, left: 2, shrink_to_fit: true, style: st
    when :right then Widget::Box.new parent: s, top: 2, right: 2, shrink_to_fit: true, style: st
    when :top   then Widget::Box.new parent: s, left: 2, top: 2, shrink_to_fit: true, style: st
    else             Widget::Box.new parent: s, left: 2, bottom: 2, shrink_to_fit: true, style: st
    end
  Widget::Box.new parent: sh, left: 0, top: 0, width: child_w, height: child_h
  s._render
  l = sh.lpos.not_nil!
  {l.xi, l.xl, l.yi, l.yl}
end

# BUGS9 §1 — shrink-to-content sizing folds in the wrong inset on the far-anchored
# (right/bottom) side. The children bounding-box span already bakes in the *near*
# inset (children sit at `parent.ileft`/`itop`, while the span is seeded to the
# parent's own edge). The near-anchored branch adds the *far* inset to reach
# `content + ihorizontal`/`ivertical`; the far-anchored branch must subtract the *far*
# inset too. Pre-fix it subtracted the *near* inset, so under an asymmetric
# border/padding a right/bottom-anchored shrink box came out `near - far` cells
# too large (and, symmetric, coincidentally correct — so this only bites
# asymmetric insets).
describe "BUGS9 shrink-to-content far-anchor uses the far inset (fix #1)" do
  it "sizes a right-anchored shrink box to content + ihorizontal under asymmetric padding" do
    pad = Crysterm::Padding.new(top: 1, bottom: 1, left: 3, right: 0)
    # Reference: the left-anchored branch is always correct.
    left = shrink_box_rect(:left, pad)
    right = shrink_box_rect(:right, pad)
    lw = left[1] - left[0]
    rw = right[1] - right[0]
    lw.should eq(9)  # content 6 + ihorizontal 3
    rw.should eq(9)  # pre-fix this was 12 (content + 2*ileft)
    rw.should eq(lw) # far anchor must match the always-correct near anchor
  end

  it "sizes a bottom-anchored shrink box to content + ivertical under asymmetric padding" do
    pad = Crysterm::Padding.new(top: 3, bottom: 0, left: 1, right: 1)
    top = shrink_box_rect(:top, pad)
    bottom = shrink_box_rect(:bottom, pad)
    th = top[3] - top[2]
    bh = bottom[3] - bottom[2]
    th.should eq(6)  # content 3 + ivertical 3
    bh.should eq(6)  # pre-fix this was 9 (content + 2*itop)
    bh.should eq(th) # far anchor must match the always-correct near anchor
  end

  it "leaves the symmetric-inset case unchanged (both anchors equal)" do
    pad = Crysterm::Padding.new(top: 2, bottom: 2, left: 2, right: 2)
    lw = shrink_box_rect(:left, pad); rw = shrink_box_rect(:right, pad)
    (lw[1] - lw[0]).should eq(10) # content 6 + ihorizontal 4
    (rw[1] - rw[0]).should eq(10)
    th = shrink_box_rect(:top, pad); bh = shrink_box_rect(:bottom, pad)
    (th[3] - th[2]).should eq(7) # content 3 + ivertical 4
    (bh[3] - bh[2]).should eq(7)
  end
end
