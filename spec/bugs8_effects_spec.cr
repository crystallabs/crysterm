require "./spec_helper"

include Crysterm

# Regression spec for the BUGS8 Spray fix: the `grow=` setter rejected only a
# fully-empty array, not an array *containing* empty strings. `recompute` reads
# `@grow[…][0]`, and `""[0]` raises `IndexError` in the render fiber. The setter
# now drops empty entries (falling back to the default if nothing remains).

describe "BUGS8 Spray#grow= rejects empty-string ramp entries" do
  it "drops empty entries from a mixed ramp" do
    spray = Crysterm::Widget::Effect::Spray.new width: 10, height: 5
    spray.grow = ["", ":", "*"]
    spray.grow.should eq [":", "*"]
    spray.grow.each(&.empty?.should(be_false))
  end

  it "falls back to the default when only empty strings are given" do
    spray = Crysterm::Widget::Effect::Spray.new width: 10, height: 5
    spray.grow = ["", ""]
    spray.grow.should eq Crysterm::Widget::Effect::Spray::DEFAULT_GROW
  end

  it "still falls back to the default on an empty array (no regression)" do
    spray = Crysterm::Widget::Effect::Spray.new width: 10, height: 5
    spray.grow = [] of String
    spray.grow.should eq Crysterm::Widget::Effect::Spray::DEFAULT_GROW
  end
end
