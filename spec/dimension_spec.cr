require "./spec_helper"

include Crysterm

# Behavior lock for the percentage arm of `Dim` (D2, parse-at-assignment):
# `Dim.parse(expr).resolve(dim)` must match the historical inline
# `expr.split(/(?=\+|-)/)` formula from widget_position/widget_size,
# reproduced below as the reference oracle — rendered geometry must not move
# under the typed representation.
describe "Dim percentage resolution" do
  # The pre-Dim (pre-extraction) computation, from the six inline blocks.
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
        Dim.parse(expr).resolve(dim).should eq old.call(expr, dim)
      end
    end
  end

  it "computes representative values directly" do
    Dim.parse("50%").resolve(80).should eq 40
    Dim.parse("50%+5").resolve(80).should eq 45
    Dim.parse("50%-5").resolve(80).should eq 35
    Dim.parse("100%").resolve(24).should eq 24
    Dim.parse("0%").resolve(24).should eq 0
    Dim.parse("25%+1").resolve(100).should eq 26
  end
end
