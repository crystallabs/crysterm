require "./spec_helper"

# `Dim` (D2): the typed geometry value parsed once at assignment. Guards the
# parser (including the malformed→raise contract that replaced the historical
# silent-0), the resolution arithmetic's parity with the legacy per-frame
# String path, the compat equalities, and the `to_s` round-trip DOM/HTML
# serialization relies on.
describe Crysterm::Dim do
  describe ".parse" do
    it "parses fixed cells from a bare integer string" do
      d = Crysterm::Dim.parse("12")
      d.cells?.should be_true
      d.offset.should eq 12
    end

    it "parses percentages with optional offsets" do
      Crysterm::Dim.parse("50%").should eq Crysterm::Dim.percent(50)
      Crysterm::Dim.parse("50%+5").should eq Crysterm::Dim.percent(50, 5)
      Crysterm::Dim.parse("50%-3").should eq Crysterm::Dim.percent(50, -3)
      Crysterm::Dim.parse("33.5%").should eq Crysterm::Dim.percent(33.5)
      Crysterm::Dim.parse("-25%").should eq Crysterm::Dim.percent(-25)
    end

    it "parses center expressions in position context" do
      Crysterm::Dim.parse("center").should eq Crysterm::Dim.center
      Crysterm::Dim.parse("center+5").should eq Crysterm::Dim.center(5)
      Crysterm::Dim.parse("center-3").should eq Crysterm::Dim.center(-3)
    end

    it "parses half as a plain 50% in size context" do
      d = Crysterm::Dim.parse("half", size: true)
      d.percent?.should be_true
      d.percent.should eq 50.0
      Crysterm::Dim.parse("half-3", size: true).should eq Crysterm::Dim.percent(50, -3)
    end

    it "parses viewport units case-insensitively" do
      Crysterm::Dim.parse("50vw").should eq Crysterm::Dim.vw(50)
      Crysterm::Dim.parse("25VH").should eq Crysterm::Dim.vh(25)
      Crysterm::Dim.parse("10vmin").should eq Crysterm::Dim.vmin(10)
      Crysterm::Dim.parse("75vmax").should eq Crysterm::Dim.vmax(75)
      Crysterm::Dim.parse(".5vw").should eq Crysterm::Dim.vw(0.5)
    end

    it "raises on malformed expressions instead of resolving to 0" do
      expect_raises(ArgumentError) { Crysterm::Dim.parse("5O%") }                # letter O
      expect_raises(ArgumentError) { Crysterm::Dim.parse("centre") }             # typo
      expect_raises(ArgumentError) { Crysterm::Dim.parse("50%+1.5") }            # fractional offset
      expect_raises(ArgumentError) { Crysterm::Dim.parse("half") }               # size word in position context
      expect_raises(ArgumentError) { Crysterm::Dim.parse("center", size: true) } # position word in size context
      expect_raises(ArgumentError) { Crysterm::Dim.parse("50vq") }               # bad viewport unit
    end

    it "returns nil from parse? on malformed input" do
      Crysterm::Dim.parse?("garbage").should be_nil
      Crysterm::Dim.parse?("50%").should_not be_nil
    end
  end

  describe ".from" do
    it "passes Int32 and nil through, canonicalizes cells Dims to Int32" do
      Crysterm::Dim.from(7).should eq 7
      Crysterm::Dim.from(nil).should be_nil
      Crysterm::Dim.from(Crysterm::Dim.cells(7)).should eq 7
    end

    it "maps :center and, in size context, :half" do
      Crysterm::Dim.from(:center).should eq Crysterm::Dim.center
      Crysterm::Dim.from(:half, size: true).should eq Crysterm::Dim.percent(50)
      expect_raises(ArgumentError) { Crysterm::Dim.from(:half) }
      expect_raises(ArgumentError) { Crysterm::Dim.from(:middle) }
    end
  end

  describe "#resolve" do
    it "matches the legacy percentage arithmetic" do
      # (against * pct).to_i + off — truncation, not rounding.
      Crysterm::Dim.percent(50).resolve(81).should eq 40
      Crysterm::Dim.percent(50, 5).resolve(80).should eq 45
      Crysterm::Dim.percent(50, -3).resolve(80).should eq 37
      Crysterm::Dim.percent(33.5).resolve(200).should eq 67
      Crysterm::Dim.center.resolve(81).should eq 40
    end

    it "resolves viewport values against the window size, rounding" do
      Crysterm::Dim.vw(50).resolve_viewport(80, 24).should eq 40
      Crysterm::Dim.vw(51).resolve_viewport(80, 24).should eq 41 # 40.8 rounds, like CSS::Length
      Crysterm::Dim.vh(50).resolve_viewport(80, 24).should eq 12
      Crysterm::Dim.vmin(100).resolve_viewport(80, 24).should eq 24
      Crysterm::Dim.vmax(100).resolve_viewport(80, 24).should eq 80
    end
  end

  describe "compat equality" do
    it "equals the spellings it was parsed from" do
      (Crysterm::Dim.parse("50%+5") == "50%+5").should be_true
      (Crysterm::Dim.parse("center") == :center).should be_true
      (Crysterm::Dim.parse("half", size: true) == :half).should be_true
      (Crysterm::Dim.parse("center") == "50%").should be_false # center pulls back half own size
    end
  end

  describe "#to_s" do
    it "round-trips through parse" do
      ["50%", "50%+5", "33.5%-2", "center", "center-3", "50vw", "25vh", "10vmin", "75vmax"].each do |s|
        d = Crysterm::Dim.parse(s)
        Crysterm::Dim.parse(d.to_s).should eq d
      end
      Crysterm::Dim.parse("half+2", size: true).to_s.should eq "50%+2"
    end
  end
end
