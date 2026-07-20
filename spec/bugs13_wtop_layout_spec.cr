require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 "Widget top-level" layout findings:
#
# * W8 — `minimal_children_rectangle` (the shrink-to-content measurer) skips
#   `layout_excluded?` chrome exactly as the layout engines do. Pre-fix, a
#   background `Media` layer pinned 0/0/0/0 spanned the widget's whole
#   stretched slot, so a `shrink_to_fit` widget locked at its parent's full size
#   after the first frame instead of tracking its real children.
# * W19 — the +/- offset parser accumulates only digit bytes; any other byte
#   makes the expression malformed. Historically malformed meant "resolves to
#   0 per frame"; with typed `Dim` geometry the same spellings are rejected up
#   front — `Dim.parse?` returns nil (the resolvers' cold raw-String arm then
#   reads 0) and assignment raises `ArgumentError`. Pre-fix any byte was
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

    s.repaint
    first = lpos_size(shrink)
    first.should eq lpos_size(ref)

    # Pre-fix the balloon hit on frames 2+ (the excluded child then measured
    # as the full stretched slot), so re-render and re-check.
    s.repaint
    lpos_size(shrink).should eq first
    lpos_size(ref).should eq first
    (first[0] < s.awidth).should be_true
    (first[1] < s.aheight).should be_true
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 W19: malformed +/- offsets are rejected" do
  it "Dim.parse resolves clean offsets and rejects non-digit ones" do
    # Clean offsets still apply...
    Dim.parse("50%+5").resolve(100).should eq 55
    Dim.parse("50%-3").resolve(100).should eq 47
    # ...malformed ones are rejected at parse time instead of folding
    # arbitrary bytes through the `*10 +` accumulator (pre-fix: "50%+1.5"
    # → 135, "50% + 5" → -155).
    Dim.parse?("50%+1.5").should be_nil
    Dim.parse?("50%+5x").should be_nil
    Dim.parse?("50%+").should be_nil
    Dim.parse?("50% + 5").should be_nil
  end

  it "center±N with a malformed offset raises at assignment" do
    s = layout_screen
    clean = Widget::Box.new parent: s, left: "center", top: 0, width: 10, height: 1
    off = Widget::Box.new parent: s, left: "center-3", top: 6, width: 10, height: 1
    expect_raises(ArgumentError) { Widget::Box.new parent: s, left: "center+abc", top: 2, width: 10, height: 1 }
    expect_raises(ArgumentError) { Widget::Box.new parent: s, left: "center+1.5", top: 4, width: 10, height: 1 }

    clean.aleft.should eq 15 # (40 * 0.5) - 10 // 2
    off.aleft.should eq clean.aleft - 3
  ensure
    s.try &.destroy
  end

  it "percentage sizes with malformed offsets raise at assignment" do
    s = layout_screen
    clean = Widget::Box.new parent: s, left: 0, top: 0, width: "50%", height: 1
    off = Widget::Box.new parent: s, left: 0, top: 4, width: "50%+5", height: 1
    expect_raises(ArgumentError) { Widget::Box.new parent: s, left: 0, top: 2, width: "50%+1.5", height: 1 }

    off.awidth.should eq clean.awidth + 5
  ensure
    s.try &.destroy
  end
end
