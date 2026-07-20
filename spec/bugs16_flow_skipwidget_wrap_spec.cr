require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 #19. Headless harness mirrors
# spec/bugs16_flow_chrome_spec.cr.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# BUGS16 #19 — when `place_one` wraps a child to a new row and then decides it
# overflows vertically (SkipWidget), the child never renders but `flow_place`
# had already advanced `@row_offset`/`@row_index`. Without un-consuming that
# wrap, every later child chains its `left` off the prior row's last rendered
# child yet takes the advanced `top`, landing on the empty new row; and
# `row_tallest`'s aheight fallback further inflates the offset by the skipped
# child's height.
describe "BUGS16 19: Flow SkipWidget on a freshly-wrapped child does not strand later children" do
  it "places the next child at the wrap origin the skipped child vacated (row-0 continuation)" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 4,
      layout: Layout::Wrap.new, overflow: Overflow::SkipWidget

    a = Widget::Box.new parent: box, width: 12, height: 3
    b = Widget::Box.new parent: box, width: 12, height: 3
    c = Widget::Box.new parent: box, width: 6, height: 1

    s._render

    bl = box.lpos.not_nil!
    xi = bl.xi
    yi = bl.yi

    # A fills row 0.
    a.lpos.not_nil!.xi.should eq xi
    a.lpos.not_nil!.yi.should eq yi

    # B wraps to row 1 (3 + 3 > 4) and is skipped: it renders nothing.
    b.lpos.should be_nil

    # C continues row 0 beside A — B consumed no wrap, so the row cursor is back
    # at 0. Pre-fix C landed at the advanced row (yi + 3), columns 0-11 empty.
    lc = c.lpos.not_nil!
    lc.xi.should eq(xi + 12)
    lc.yi.should eq yi
    (lc.xl - lc.xi).should eq 6
    (lc.yl - lc.yi).should eq 1
  end

  it "still renders a later child once its own wrap fits, ignoring a taller skipped child's height" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::Wrap.new, overflow: Overflow::SkipWidget

    a = Widget::Box.new parent: box, width: 12, height: 3
    b = Widget::Box.new parent: box, width: 12, height: 20
    c = Widget::Box.new parent: box, width: 18, height: 2

    s._render

    bl = box.lpos.not_nil!
    yi = bl.yi

    a.lpos.should_not be_nil
    # B wraps then overflows vertically (3 + 20 > 10) and is skipped.
    b.lpos.should be_nil

    # C wraps below A (it is 18 wide, doesn't fit beside 12-wide A) and renders
    # at rows 3-4 relative to the interior. Pre-fix, row_tallest counted the
    # skipped B's height 20, pushing C's top to 20 and skipping C too.
    lc = c.lpos.not_nil!
    lc.yi.should eq(yi + 3)
    lc.xi.should eq bl.xi
    (lc.yl - lc.yi).should eq 2
  end

  it "leaves the whole later flow correctly placed for Masonry too" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 4,
      layout: Layout::Masonry.new, overflow: Overflow::SkipWidget

    Widget::Box.new parent: box, width: 12, height: 3
    b = Widget::Box.new parent: box, width: 12, height: 3
    c = Widget::Box.new parent: box, width: 6, height: 1

    s._render

    bl = box.lpos.not_nil!

    b.lpos.should be_nil
    lc = c.lpos.not_nil!
    lc.xi.should eq(bl.xi + 12)
    lc.yi.should eq bl.yi
  end
end
