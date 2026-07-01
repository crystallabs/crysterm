require "./spec_helper"

include Crysterm

# Behavior lock for `SidedGeometry` — the per-side helpers shared by
# `Margin`/`Padding`/`Border`: the `.sides` symbol expander, the `.from(Symbol)`
# convenience path, the per-side predicates, and both `#adjust` arities.
describe Crysterm::SidedGeometry do
  describe ".sides" do
    it "expands single-side symbols" do
      Crysterm::SidedGeometry.sides(:left).should eq({left: 1, top: 0, right: 0, bottom: 0})
      Crysterm::SidedGeometry.sides(:top).should eq({left: 0, top: 1, right: 0, bottom: 0})
      Crysterm::SidedGeometry.sides(:right).should eq({left: 0, top: 0, right: 1, bottom: 0})
      Crysterm::SidedGeometry.sides(:bottom).should eq({left: 0, top: 0, right: 0, bottom: 1})
    end

    it "expands axis and all/none symbols" do
      Crysterm::SidedGeometry.sides(:horizontal).should eq({left: 1, top: 0, right: 1, bottom: 0})
      Crysterm::SidedGeometry.sides(:x).should eq({left: 1, top: 0, right: 1, bottom: 0})
      Crysterm::SidedGeometry.sides(:vertical).should eq({left: 0, top: 1, right: 0, bottom: 1})
      Crysterm::SidedGeometry.sides(:y).should eq({left: 0, top: 1, right: 0, bottom: 1})
      Crysterm::SidedGeometry.sides(:all).should eq({left: 1, top: 1, right: 1, bottom: 1})
      Crysterm::SidedGeometry.sides(:none).should eq({left: 0, top: 0, right: 0, bottom: 0})
    end

    it "honors a custom amount" do
      Crysterm::SidedGeometry.sides(:horizontal, 3).should eq({left: 3, top: 0, right: 3, bottom: 0})
    end

    it "raises ArgumentError on an unknown symbol" do
      expect_raises(ArgumentError, /Unknown side symbol/) do
        Crysterm::SidedGeometry.sides(:sideways)
      end
    end
  end

  describe "Margin.from(Symbol)" do
    it "builds a one-cell margin on the named side" do
      m = Margin.from(:right)
      {m.left, m.top, m.right, m.bottom}.should eq({0, 0, 1, 0})
    end

    it "builds all-sides via :all and zero via :none" do
      a = Margin.from(:all)
      {a.left, a.top, a.right, a.bottom}.should eq({1, 1, 1, 1})
      z = Margin.from(:none)
      {z.left, z.top, z.right, z.bottom}.should eq({0, 0, 0, 0})
    end
  end

  describe ".default" do
    it "returns a fresh zero box, not a shared singleton" do
      a = Padding.default
      b = Padding.default
      a.should_not be b
      a.left = 5
      b.left.should eq 0 # mutation of one must not leak into the other
    end
  end

  describe "predicates" do
    it "reports per-side presence and any?" do
      m = Margin.new 0, 2, 0, 0
      m.left?.should be_false
      m.top?.should be_true
      m.right?.should be_false
      m.bottom?.should be_false
      m.any?.should be_true

      Margin.new(0).any?.should be_false
    end
  end

  describe "#adjust (by value)" do
    it "grows a rectangle outward with sign +1" do
      m = Margin.new 1, 2, 3, 4 # l, t, r, b
      # xi, xl, yi, yl
      m.adjust(10, 20, 30, 40, 1).should eq({11, 17, 32, 36})
    end

    it "shrinks a rectangle inward with sign -1" do
      m = Margin.new 1, 2, 3, 4
      m.adjust(10, 20, 30, 40, -1).should eq({9, 23, 28, 44})
    end
  end

  describe "#adjust (in place)" do
    it "mutates the passed position by the per-side amounts" do
      m = Margin.new 1, 2, 3, 4
      pos = LPos.new xi: 10, xl: 20, yi: 30, yl: 40
      m.adjust(pos, 1)
      {pos.xi, pos.xl, pos.yi, pos.yl}.should eq({11, 17, 32, 36})
    end
  end
end
