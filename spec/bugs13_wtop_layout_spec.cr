require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 "Widget top-level" layout findings:
#
# * W8 — `minimal_children_rectangle` (the shrink-to-content measurer) skips
#   `layout_excluded?` chrome exactly as the layout engines do. Pre-fix, a
#   background `Media` layer pinned 0/0/0/0 spanned the widget's whole
#   stretched slot, so a `shrink_to_fit` widget locked at its parent's full size
#   after the first frame instead of tracking its real children.
# * W19 — `Widget.resolve_percentage`'s +/- offset parser (and the `center±N` path in
#   `resolve_dimension`) accumulates only digit bytes; any other byte makes
#   the offset 0 (the documented malformed→0 contract). Pre-fix any byte was
#   folded through the `*10 +` accumulator, producing garbage coordinates
#   ("50%+1.5" → 135, "50% + 5" → -155).

private def layout_screen(w = 40, h = 12)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h, default_quit_keys: false)
end

private def lpos_size(widget)
  l = widget.lpos.not_nil!
  {l.xl - l.xi, l.yl - l.yi}
end

describe "BUGS13 W8: shrink-to-content skips layout_excluded chrome" do
  it "a full-slot excluded child does not balloon the shrink size across renders" do
    s = layout_screen
    shrink = Widget::Box.new parent: s, top: 0, left: 0, shrink_to_fit: true
    Widget::Box.new parent: shrink, top: 0, left: 0, width: 6, height: 2,
      content: "hi"
    # Chrome spanning the whole slot, exactly like the background-image Media
    # layer (`ensure_background_media`): pinned 0/0/0/0 + layout_excluded.
    chrome = Widget::Box.new parent: shrink, top: 0, left: 0, right: 0, bottom: 0
    chrome.layout_excluded = true

    # Ground truth: an identical shrink widget without the chrome child.
    ref = Widget::Box.new parent: s, top: 5, left: 0, shrink_to_fit: true
    Widget::Box.new parent: ref, top: 0, left: 0, width: 6, height: 2,
      content: "hi"

    s._render
    first = lpos_size(shrink)
    first.should eq lpos_size(ref)

    # Pre-fix the balloon hit on frames 2+ (the excluded child then measured
    # as the full stretched slot), so re-render and re-check.
    s._render
    lpos_size(shrink).should eq first
    lpos_size(ref).should eq first
    (first[0] < s.awidth).should be_true
    (first[1] < s.aheight).should be_true
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 W19: malformed +/- offsets read as 0" do
  it "Widget.resolve_percentage accumulates only digit offsets" do
    # Clean offsets still apply...
    Widget.resolve_percentage("50%+5", 100).should eq 55
    Widget.resolve_percentage("50%-3", 100).should eq 47
    # ...malformed ones read as 0 instead of folding arbitrary bytes.
    Widget.resolve_percentage("50%+1.5", 100).should eq 50 # pre-fix: 135 (dim 270)
    Widget.resolve_percentage("50%+5x", 100).should eq 50
    Widget.resolve_percentage("50%+", 100).should eq 50
    # The space also breaks the percentage parse, so the whole expression is
    # malformed → 0 (pre-fix: -155).
    Widget.resolve_percentage("50% + 5", 100).should eq 0
  end

  it "center±N with a malformed offset positions like plain center" do
    s = layout_screen
    clean = Widget::Box.new parent: s, left: "center", top: 0, width: 10, height: 1
    mal1 = Widget::Box.new parent: s, left: "center+abc", top: 2, width: 10, height: 1
    mal2 = Widget::Box.new parent: s, left: "center+1.5", top: 4, width: 10, height: 1
    off = Widget::Box.new parent: s, left: "center-3", top: 6, width: 10, height: 1

    clean.aleft.should eq 15 # (40 * 0.5) - 10 // 2
    mal1.aleft.should eq clean.aleft
    mal2.aleft.should eq clean.aleft
    off.aleft.should eq clean.aleft - 3
  end

  it "percentage sizes with malformed offsets resolve as offset 0" do
    s = layout_screen
    clean = Widget::Box.new parent: s, left: 0, top: 0, width: "50%", height: 1
    mal = Widget::Box.new parent: s, left: 0, top: 2, width: "50%+1.5", height: 1
    off = Widget::Box.new parent: s, left: 0, top: 4, width: "50%+5", height: 1

    mal.awidth.should eq clean.awidth
    off.awidth.should eq clean.awidth + 5
  end
end
