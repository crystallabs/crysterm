require "./spec_helper"

include Crysterm

# Regression specs for the BUGS5 lifecycle fixes:
#
#  1. `Widget#stack_index=` (used by `#to_front`/`#to_back`) reordered the parent's
#     children list directly (`insert index, delete_at i`), bypassing the
#     `Mixin::Children#insert`/`#remove` path and therefore
#     `mark_structure_changed`. Under `OptimizationFlag::DamageTracking` a lone
#     `to_front`/`to_back` left the dirty set empty, so the compositor produced a
#     fast frame and the new stacking order was not painted; order-dependent CSS
#     selectors also did not re-evaluate. The reorder must mark the moved widget
#     dirty, force a full re-composite, and invalidate the CSS tree.
#
#  2. `Window#capture_animation` registered the `Rendered` frame-writer handler
#     BEFORE writing the first frame. The first frame overflows the pipe buffer
#     and yields mid-write, during which the render fiber could emit `Rendered`
#     and interleave a second frame into ffmpeg's stdin, corrupting the stream.
#     The first frame must be written before the handler registers. A runtime
#     spec would need ffmpeg and a live render loop, so this is guarded with a
#     source-order assertion instead (see note in that describe block).

describe "BUGS5 z-order reorder invalidation (fix #1)" do
  it "#to_front on a nested widget marks it dirty and invalidates the CSS tree" do
    s = headless_screen(80, 24)
    parent = Crysterm::Widget::Box.new(parent: s, top: 0, left: 0, width: 20, height: 10)
    a = Crysterm::Widget::Box.new(parent: parent, top: 0, left: 0, width: 5, height: 1)
    Crysterm::Widget::Box.new(parent: parent, top: 1, left: 0, width: 5, height: 1)

    # Render once to clear any pending dirty/CSS state.
    s.render
    a.render_dirty = false

    # `a` starts before `b`; bring it to front (last slot).
    parent.children.index(a).should eq 0
    a.to_front

    parent.children.last.should eq a
    a.render_dirty?.should be_true
    s.css_dirty?.should be_true
  end

  it "#to_back on a nested widget reorders it and invalidates" do
    s = headless_screen(80, 24)
    parent = Crysterm::Widget::Box.new(parent: s, top: 0, left: 0, width: 20, height: 10)
    Crysterm::Widget::Box.new(parent: parent, top: 0, left: 0, width: 5, height: 1)
    b = Crysterm::Widget::Box.new(parent: parent, top: 1, left: 0, width: 5, height: 1)

    s.render
    b.render_dirty = false

    parent.children.index(b).should eq 1
    b.to_back

    parent.children.first.should eq b
    b.render_dirty?.should be_true
    s.css_dirty?.should be_true
  end

  it "#to_front on a top-level widget (window parent) reorders and invalidates" do
    s = headless_screen(80, 24)
    a = Crysterm::Widget::Box.new(parent: s, top: 0, left: 0, width: 5, height: 1)
    Crysterm::Widget::Box.new(parent: s, top: 1, left: 0, width: 5, height: 1)

    s.render
    a.render_dirty = false

    s.children.index(a).should eq 0
    a.to_front

    s.children.last.should eq a
    a.render_dirty?.should be_true
    s.css_dirty?.should be_true
  end

  it "#to_front is a no-op (no reorder) when already at the front slot" do
    s = headless_screen(80, 24)
    parent = Crysterm::Widget::Box.new(parent: s, top: 0, left: 0, width: 20, height: 10)
    Crysterm::Widget::Box.new(parent: parent, top: 0, left: 0, width: 5, height: 1)
    b = Crysterm::Widget::Box.new(parent: parent, top: 1, left: 0, width: 5, height: 1)

    s.render
    b.render_dirty = false

    # `b` is already last (front): calling to_front must not churn dirty/CSS state.
    parent.children.last.should eq b
    b.to_front

    parent.children.last.should eq b
    b.render_dirty?.should be_false
  end
end

describe "BUGS5 capture_animation first-frame ordering (fix #2)" do
  # A true runtime test needs ffmpeg plus a live render loop racing pipe writes,
  # which isn't feasible here. Instead assert the structural invariant: the
  # first-frame `input.write` must complete before the async frame writer
  # starts, so the two never interleave on ffmpeg's stdin. The async writer is
  # a `FrameClock` sampler (`feed_animation_frames`), so the invariant is
  # "first write precedes `clock.start`".
  it "writes the first frame before starting the FrameClock sampler" do
    # `feed_animation_frames` lives in window_capture.cr; the examined slice
    # ends at the next def.
    src = File.read(File.join(__DIR__, "..", "src", "window_capture.cr"))
    body_start = src.index!("def feed_animation_frames")
    body_end = src.index!("def capture_cursor_overlay", body_start)
    body = src[body_start...body_end]

    # Frame 0 is rendered into `last` (the repeat-fill source) and written from
    # there, so the marker is that write, not a `Capture.rgba(first)` call.
    first_write = body.index!("input.write last rescue nil")
    clock_start = body.index!("clock.start")

    first_write.should be < clock_start
    # The per-Rendered frame scheme is gone entirely (BUGS13 C11).
    body.includes?("Event::Rendered").should be_false
  end
end
