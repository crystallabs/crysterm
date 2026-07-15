require "./spec_helper"

include Crysterm

# Behavior lock for `Widget.resolve_percentage` (the extracted percentage position/size
# resolver): must match the previous inline `expr.split(/(?=\+|-)/)` formula
# from widget_position/widget_size, reproduced below as the reference oracle.
describe "Widget.resolve_percentage" do
  # Pre-extraction computation (the six inline blocks).
  old = ->(expr : String, dim : Int32) {
    e = expr.split(/(?=\+|-)/)
    base = e[0][0...-1].to_f / 100
    v = (dim * base).to_i
    v += e[1].to_i if e[1]?
    v
  }

  exprs = [
    "0%", "50%", "100%", "33%", "75%",
    "50%+5", "50%-3", "25%+10", "75%-20", "100%-1",
    "33.5%", "12.5%+4", "66.6%-2", "0%+7",
  ]
  dims = [0, 1, 10, 24, 80, 100, 237]

  it "matches the old split-based formula for all expr/dim combinations" do
    exprs.each do |expr|
      dims.each do |dim|
        Widget.resolve_percentage(expr, dim).should eq old.call(expr, dim)
      end
    end
  end

  it "computes representative values directly" do
    Widget.resolve_percentage("50%", 80).should eq 40
    Widget.resolve_percentage("50%+5", 80).should eq 45
    Widget.resolve_percentage("50%-5", 80).should eq 35
    Widget.resolve_percentage("100%", 24).should eq 24
    Widget.resolve_percentage("0%", 24).should eq 0
    Widget.resolve_percentage("25%+1", 100).should eq 26
  end
end
