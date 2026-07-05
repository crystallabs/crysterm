require "./spec_helper"

include Crysterm

# `Widget::Graph::Scale.fmt` drops the `.0` from whole numbers via `v.to_i64`.
# For a non-finite value, `v == v.round` is true (`Infinity.round == Infinity`),
# so it took the whole-number branch and called `Infinity.to_i64` — an
# `OverflowError` that crashed the render fiber. Such values reach `fmt` from
# plotted data (a divide-by-zero, `Math.log(0)`, etc.) via every graph widget
# that formats numbers (Gauge/Bar/StackedBar/GaugeList/Donut/LineChart/HeatMap).
# `fmt` now returns the plain string form for non-finite values.

describe "Widget::Graph::Scale.fmt with non-finite values" do
  it "formats Infinity without raising OverflowError" do
    Crysterm::Widget::Graph::Scale.fmt(Float64::INFINITY).should eq "Infinity"
    Crysterm::Widget::Graph::Scale.fmt(-Float64::INFINITY).should eq "-Infinity"
  end

  it "formats NaN as its plain string" do
    Crysterm::Widget::Graph::Scale.fmt(Float64::NAN).should eq "NaN"
  end

  it "still formats ordinary finite values" do
    Crysterm::Widget::Graph::Scale.fmt(5.0).should eq "5"
    Crysterm::Widget::Graph::Scale.fmt(2.34).should eq "2.3"
  end
end
