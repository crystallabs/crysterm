require "./spec_helper"

include Crysterm

# Regression specs for the BUGS5 lifecycle fixes:
#
#  1. `Widget#set_index` (used by `#front!`/`#back!`) reordered the parent's
#     children list directly (`insert index, delete_at i`), bypassing the
#     `Mixin::Children#insert`/`#remove` path and therefore
#     `mark_structure_changed`. Under `OptimizationFlag::DamageTracking` a lone
#     `front!`/`back!` left the dirty set empty, so the compositor produced a
#     fast frame and the new stacking order was not painted; order-dependent CSS
#     selectors also did not re-evaluate. The fix marks the moved widget dirty,
#     forces a full re-composite, and invalidates the CSS tree.
#
#  2. `Window#capture_animation` registered the `Rendered` frame-writer handler
#     BEFORE writing the first frame. The first frame overflows the pipe buffer
#     and yields mid-write, during which the render fiber could emit `Rendered`
#     and interleave a second frame into ffmpeg's stdin, corrupting the stream.
#     The fix writes the first frame before registering the handler. A runtime
#     spec would need ffmpeg and a live render loop, so this is guarded with a
#     source-order assertion instead (see note in that describe block).

private def lifecycle_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS5 z-order reorder invalidation (fix #1)" do
  it "#front! on a nested widget marks it dirty and invalidates the CSS tree" do
    s = lifecycle_screen
    parent = Crysterm::Widget::Box.new(parent: s, top: 0, left: 0, width: 20, height: 10)
    a = Crysterm::Widget::Box.new(parent: parent, top: 0, left: 0, width: 5, height: 1)
    Crysterm::Widget::Box.new(parent: parent, top: 1, left: 0, width: 5, height: 1)

    # Render once to clear any pending dirty/CSS state.
    s.render
    a.render_dirty = false

    # `a` starts before `b`; bring it to front (last slot).
    parent.children.index(a).should eq 0
    a.front!

    parent.children.last.should eq a
    a.render_dirty.should be_true
    s.css_dirty?.should be_true
  end

  it "#back! on a nested widget reorders it and invalidates" do
    s = lifecycle_screen
    parent = Crysterm::Widget::Box.new(parent: s, top: 0, left: 0, width: 20, height: 10)
    Crysterm::Widget::Box.new(parent: parent, top: 0, left: 0, width: 5, height: 1)
    b = Crysterm::Widget::Box.new(parent: parent, top: 1, left: 0, width: 5, height: 1)

    s.render
    b.render_dirty = false

    parent.children.index(b).should eq 1
    b.back!

    parent.children.first.should eq b
    b.render_dirty.should be_true
    s.css_dirty?.should be_true
  end

  it "#front! on a top-level widget (window parent) reorders and invalidates" do
    s = lifecycle_screen
    a = Crysterm::Widget::Box.new(parent: s, top: 0, left: 0, width: 5, height: 1)
    Crysterm::Widget::Box.new(parent: s, top: 1, left: 0, width: 5, height: 1)

    s.render
    a.render_dirty = false

    s.children.index(a).should eq 0
    a.front!

    s.children.last.should eq a
    a.render_dirty.should be_true
    s.css_dirty?.should be_true
  end

  it "#front! is a no-op (no reorder) when already at the front slot" do
    s = lifecycle_screen
    parent = Crysterm::Widget::Box.new(parent: s, top: 0, left: 0, width: 20, height: 10)
    Crysterm::Widget::Box.new(parent: parent, top: 0, left: 0, width: 5, height: 1)
    b = Crysterm::Widget::Box.new(parent: parent, top: 1, left: 0, width: 5, height: 1)

    s.render
    b.render_dirty = false

    # `b` is already last (front): calling front! must not churn dirty/CSS state.
    parent.children.last.should eq b
    b.front!

    parent.children.last.should eq b
    b.render_dirty.should be_false
  end
end

describe "BUGS5 capture_animation first-frame ordering (fix #2)" do
  # A true runtime test needs ffmpeg plus a live render loop racing pipe writes,
  # which isn't feasible here. Instead assert the structural invariant the fix
  # relies on: within `capture_animation`, the first-frame `input.write` must
  # precede registering the `Rendered` handler, so the two never interleave on
  # ffmpeg's stdin.
  it "writes the first frame before registering the Rendered handler" do
    src = File.read(File.join(__DIR__, "..", "src", "window_capture.cr"))
    body_start = src.index!("private def capture_animation")
    body_end = src.index!("private def run_ffmpeg", body_start)
    body = src[body_start...body_end]

    first_write = body.index!("input.write Capture.rgba(first)")
    handler_register = body.index!("on(::Crysterm::Event::Rendered)")

    first_write.should be < handler_register
  end
end
