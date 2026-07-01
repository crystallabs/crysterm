require "./spec_helper"

include Crysterm

# `Shadow.default` is the per-`Style` default shadow ("no shadow"). Like
# `Padding.default`/`Margin.default`, it must return a *fresh* instance, not a
# shared singleton: `Shadow` is mutable via its per-side/alpha setters, and
# `Style` gives one to every instance (`getter shadow = Shadow.default`). A
# shared object would let an in-place edit leak into every other style's default.
describe Crysterm::Shadow do
  describe ".default" do
    it "returns a distinct zero-shadow each call (not a shared singleton)" do
      a = Shadow.default
      b = Shadow.default
      a.same?(b).should be_false
      a.any?.should be_false
      {a.left, a.top, a.right, a.bottom}.should eq({0, 0, 0, 0})
    end

    it "does not leak an in-place per-side edit across instances" do
      a = Shadow.default
      b = Shadow.default
      a.bottom = 5
      b.bottom.should eq 0
    end
  end

  it "gives each Style its own default shadow object" do
    s1 = Style.new
    s2 = Style.new
    s1.shadow.same?(s2.shadow).should be_false
    # Mutating one style's default shadow must not affect another's.
    s1.shadow.right = 9
    s2.shadow.right.should eq 0
  end
end
