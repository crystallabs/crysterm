require "./spec_helper"

include Crysterm

# plans/SIZE-POLICY-PLAN.md Phase 3 (§4.4 half 2, §1.8) — `Widget::SizePolicy`,
# `size_hint`/`minimum_size_hint`/`adjust_size`, and `Layout::Box` consuming
# the policy. The default `Auto` derives the behavior from the size spec, so a
# program that never touches `size_policy` arranges bit-identically — the rest
# of the layout suite is the golden for that.

describe Widget::SizePolicy do
  it "defaults to Auto on both axes" do
    p = Widget::SizePolicy.new
    p.horizontal.auto?.should be_true
    p.vertical.auto?.should be_true
  end

  it "autocasts symbols in the constructor" do
    p = Widget::SizePolicy.new :preferred, :expanding
    p.horizontal.preferred?.should be_true
    p.vertical.expanding?.should be_true
  end

  it "set_size_policy sets both axes through the change-guarded setter" do
    s = headless_screen(80, 24)
    w = Widget::Box.new parent: s
    w.set_size_policy :fixed, :preferred
    w.size_policy.should eq Widget::SizePolicy.new(:fixed, :preferred)
  end
end

describe "size_hint (§1.8)" do
  it "reports the content extent plus frame insets" do
    s = headless_screen(80, 24)
    w = Widget::Box.new parent: s, content: "Hello\nWo"
    w.size_hint.should eq Size.new(5, 2)

    b = Widget::Box.new parent: s, content: "Hi",
      style: Style.new(border: true)
    b.size_hint.should eq Size.new(2 + 2, 1 + 2)
  end

  it "minimum_size_hint is the frame insets alone" do
    s = headless_screen(80, 24)
    plain = Widget::Box.new parent: s
    plain.minimum_size_hint.should eq Size.new(0, 0)
    bordered = Widget::Box.new parent: s, style: Style.new(border: true)
    bordered.minimum_size_hint.should eq Size.new(2, 2)
  end

  it "a Spacer's hint is its declared size; a stretch spacer's is 0×0" do
    Widget::Spacer.new(5).size_hint.should eq Size.new(5, 5)
    Widget::Spacer.stretch(2).size_hint.should eq Size.new(0, 0)
  end
end

describe "adjust_size (§1.8)" do
  it "resizes to the hint, writing the specs" do
    s = headless_screen(80, 24)
    w = Widget::Box.new parent: s, left: 0, top: 0, content: "Hello\nWorld!"
    w.adjust_size
    w.width_spec.should eq 6
    w.height_spec.should eq 2
  end

  it "is bounded by the parent's content area" do
    s = headless_screen(80, 24)
    tall = Widget::Box.new parent: s, left: 0, top: 0,
      content: Array.new(40, "x").join('\n')
    tall.adjust_size
    tall.height_spec.should eq 24
  end
end

describe "Layout::Box consumes SizePolicy (§4.4)" do
  it "Preferred: a label-like child sizes to its text in an HBox" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new
    label = Widget::Box.new parent: box, content: "Hello"
    label.size_policy = Widget::SizePolicy.new(:preferred, :auto)
    rest = Widget::Box.new parent: box

    s.repaint
    label.awidth.should eq 5       # sized to the hint, not a flex share
    label.aheight.should eq 5      # cross axis still stretches (Auto + nil spec)
    rest.awidth.should eq 25       # the flex child takes the rest
    label.width_spec.should be_nil # the hint went through the layout channel
  end

  it "Preferred is never grown, and shrinks when space runs short" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 4, height: 3,
      layout: Layout::HBox.new
    label = Widget::Box.new parent: box, content: "Hello, world"
    label.size_policy = Widget::SizePolicy.new(:preferred, :auto)

    s.repaint
    label.awidth.should eq 4 # the hint (12) clamped to the interior
  end

  it "Preferred works on the cross axis under Stretch align" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::HBox.new
    label = Widget::Box.new parent: box, content: "One\nTwo"
    label.size_policy = Widget::SizePolicy.new(:auto, :preferred)

    s.repaint
    label.aheight.should eq 2 # hint height, not the stretched 10
    label.awidth.should eq 30 # main axis still flexes (Auto + nil spec)
  end

  it "Fixed overrides a nil spec: the child keeps its resolved size instead of flexing" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new
    c1 = Widget::Box.new parent: box
    c1.size_policy = Widget::SizePolicy.new(:fixed, :auto)
    c2 = Widget::Box.new parent: box

    s.repaint
    # A nil width resolves to the parent's content extent; Fixed means the
    # engine takes that as authoritative instead of assigning a flex share.
    c1.awidth.should eq 30
    c2.awidth.should eq 0
  end

  it "Expanding overrides an explicit spec: the child joins the flex share, spec untouched" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new
    c1 = Widget::Box.new parent: box, width: 10
    c1.size_policy = Widget::SizePolicy.new(:expanding, :auto)
    c2 = Widget::Box.new parent: box

    s.repaint
    c1.awidth.should eq 15
    c2.awidth.should eq 15
    c1.width_spec.should eq 10 # the spec survives untouched
  end

  it "a policy change re-arranges on the next frame" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new
    c1 = Widget::Box.new parent: box, width: 10
    c2 = Widget::Box.new parent: box

    s.repaint
    c1.awidth.should eq 10
    c2.awidth.should eq 20

    c1.size_policy = Widget::SizePolicy.new(:expanding, :auto)
    s.repaint
    c1.awidth.should eq 15
    c2.awidth.should eq 15
  end
end
