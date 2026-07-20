require "./spec_helper"

include Crysterm

# BUGS12 #16 — `min_width`/`max_width` (and height) constraints were ignored for
# `shrink_to_fit` (shrink-to-content) widgets: `clamp_awidth`/`clamp_aheight` run
# only inside `awidth`/`aheight`, and `coords`' `shrink_to_fit?` branch
# overwrote the rectangle from `minimal_rectangle` without re-clamping, so the
# content-derived size bypassed the constraints entirely. The re-clamp must
# respect the anchored edge: a right/bottom-anchored shrink keeps its far edge
# and moves `xi`/`yi`; every other anchoring keeps the near edge.

private def headless_screen(w = 60, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def rendered_rect(widget, s)
  s.repaint
  l = widget.lpos.not_nil!
  {l.xi, l.xl, l.yi, l.yl}
end

describe "BUGS12 #16 shrink-to-content respects min/max size constraints" do
  it "caps a left-anchored shrink_to_fit widget's content-derived width at max_width" do
    s = headless_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, shrink_to_fit: true,
      content: "x" * 30
    b.max_width = 12
    xi, xl, _, _ = rendered_rect(b, s)
    xi.should eq 0 # near (left) edge anchored
    (xl - xi).should eq 12
  end

  it "caps a right-anchored shrink_to_fit widget's width by moving xi, keeping xl" do
    s = headless_screen
    # Unconstrained reference: shrink keeps the far (right) edge.
    r0 = Widget::Box.new parent: s, top: 0, right: 0, shrink_to_fit: true,
      content: "x" * 30
    xi0, xl0, _, _ = rendered_rect(r0, s)
    (xl0 - xi0).should eq 30

    s2 = headless_screen
    b = Widget::Box.new parent: s2, top: 0, right: 0, shrink_to_fit: true,
      content: "x" * 30
    b.max_width = 12
    xi, xl, _, _ = rendered_rect(b, s2)
    xl.should eq xl0 # far (right) edge anchored — clamping must not move it
    (xl - xi).should eq 12
  end

  it "expands a shrink_to_fit widget's content-derived width up to min_width" do
    s = headless_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, shrink_to_fit: true,
      content: "hi"
    b.min_width = 15
    xi, xl, _, _ = rendered_rect(b, s)
    xi.should eq 0
    (xl - xi).should eq 15
  end

  it "caps a top-anchored shrink_to_fit widget's content-derived height at max_height" do
    s = headless_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, shrink_to_fit: true,
      content: "a\nb\nc\nd\ne\nf"
    b.max_height = 3
    _, _, yi, yl = rendered_rect(b, s)
    yi.should eq 0 # near (top) edge anchored
    (yl - yi).should eq 3
  end

  it "caps a bottom-anchored shrink_to_fit widget's height by moving yi, keeping yl" do
    s = headless_screen
    r0 = Widget::Box.new parent: s, left: 0, bottom: 0, shrink_to_fit: true,
      content: "a\nb\nc\nd\ne\nf"
    _, _, yi0, yl0 = rendered_rect(r0, s)
    (yl0 - yi0).should eq 6

    s2 = headless_screen
    b = Widget::Box.new parent: s2, left: 0, bottom: 0, shrink_to_fit: true,
      content: "a\nb\nc\nd\ne\nf"
    b.max_height = 3
    _, _, yi, yl = rendered_rect(b, s2)
    yl.should eq yl0 # far (bottom) edge anchored — clamping must not move it
    (yl - yi).should eq 3
  end

  it "expands a shrink_to_fit widget's content-derived height up to min_height" do
    s = headless_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, shrink_to_fit: true,
      content: "one line"
    b.min_height = 5
    _, _, yi, yl = rendered_rect(b, s)
    yi.should eq 0
    (yl - yi).should eq 5
  end

  it "clamps each axis independently (fixed width, shrunk height)" do
    s = headless_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, shrink_to_fit: true,
      content: "a\nb\nc\nd\ne\nf"
    b.max_height = 3
    xi, xl, yi, yl = rendered_rect(b, s)
    (xl - xi).should eq 10 # explicit width untouched
    (yl - yi).should eq 3
  end

  it "leaves an unconstrained shrink_to_fit widget's shrink result unchanged" do
    s = headless_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, shrink_to_fit: true,
      content: "x" * 30
    xi, xl, yi, yl = rendered_rect(b, s)
    (xl - xi).should eq 30
    (yl - yi).should eq 1
  end

  it "leaves a non-shrink_to_fit widget's clamped size unchanged" do
    s = headless_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 30,
      content: "x" * 30
    b.max_width = 12
    xi, xl, _, _ = rendered_rect(b, s)
    # `awidth` already clamps the explicit width; unchanged by the shrink fix.
    (xl - xi).should eq 12
  end
end
