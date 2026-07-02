require "./spec_helper"

include Crysterm

# Regression spec for the BUGS8 numeric-formatter fix: `Graph::Scale.fmt` used
# `Float64#to_i` (Int32), which raises `OverflowError` for any integer-valued
# magnitude ≥ ~2.147e9 — ordinary large data (byte counts, populations,
# timestamps). It now uses `to_i64`.

describe "BUGS8 Graph::Scale.fmt handles integer values ≥ 2³¹" do
  it "does not overflow on a large integer-valued float" do
    Crysterm::Widget::Graph::Scale.fmt(3_000_000_000.0).should eq "3000000000"
  end

  it "still drops the .0 on small integers and rounds fractions" do
    Crysterm::Widget::Graph::Scale.fmt(42.0).should eq "42"
    Crysterm::Widget::Graph::Scale.fmt(3.14159).should eq "3.1"
  end

  it "handles a large negative integer too" do
    Crysterm::Widget::Graph::Scale.fmt(-5_000_000_000.0).should eq "-5000000000"
  end
end
