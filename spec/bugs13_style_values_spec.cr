require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 style/config value-parsing batch:
#
# * S5  — `url(...)` matched case-insensitively (`URL("x.png")` must not be
#   treated as "no url" and clear the background image).
# * S7  — `alternate-background-color` seeds the alternate-row style from the
#   documented `cell` → `self` fallback, so only the background role changes.
# * S11 — `Length.to_cells`/`to_cells_f`/`viewport_cells` return `nil` (never
#   raise) on out-of-Float64-range numeric literals.
# * S12 — `opacity: nan`/`inf` is dropped instead of storing a non-finite
#   alpha (which crashed `Colors.mix` on the first blended cell).
# * S13 — `parse_time` rejects overflow/nan/inf durations instead of raising
#   `OverflowError` mid-cascade.
# * S14 — a negative `transition` duration invalidates the entry (previously
#   it built an immortal 30fps FrameClock pinned at the from-value).
# * S15 — comment stripping honors quoted strings (`url("/a/*x*/b.png")`).

private def rgb(name)
  Crysterm::Colors.convert(name).to_i32
end

describe "BUGS13 S5 url(...) is matched case-insensitively" do
  it "parses URL(...) / Url(...) like url(...)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-image", %q(URL("x.png")))
    s.background_image.should eq "x.png"
    Crysterm::CSS::Properties.apply(s, "background-image", %q(Url('y.png')))
    s.background_image.should eq "y.png"
  end

  it "does not clear a set image when the uppercase spelling re-applies it" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-image", %q(url("x.png")))
    Crysterm::CSS::Properties.apply(s, "background-image", %q(URL("x.png")))
    s.background_image.should eq "x.png"
  end

  it "still clears the image on `none`" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-image", %q(url("x.png")))
    Crysterm::CSS::Properties.apply(s, "background-image", "none")
    s.background_image.should be_nil
  end

  it "extracts an uppercase URL(...) from the background shorthand" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background", %q(red URL("z.png")))
    s.background_image.should eq "z.png"
    s.bg.should eq rgb("red")
  end
end

describe "BUGS13 S7 alternate-background-color seeds from the cell fallback" do
  it "keeps the table text color and attributes on alternate rows" do
    s = Style.new
    s.fg = "yellow"
    s.bold = true
    Crysterm::CSS::Properties.apply(s, "alternate-background-color", "blue")
    alt = s.alternate_row
    alt.bg.should eq rgb("blue")
    alt.fg.should eq rgb("yellow") # was nil (style_to_attr maps nil fg -> -1)
    alt.bold?.should be_true       # was false
  end

  it "seeds from an explicit cell sub-style when one is set" do
    s = Style.new
    s.fg = "yellow"
    cell = Style.new
    cell.fg = "cyan"
    s.cell = cell
    Crysterm::CSS::Properties.apply(s, "alternate-background-color", "blue")
    s.alternate_row.fg.should eq rgb("cyan")
  end

  it "changes only the background on re-assignment (existing sub-style kept)" do
    s = Style.new
    s.fg = "yellow"
    Crysterm::CSS::Properties.apply(s, "alternate-background-color", "blue")
    Crysterm::CSS::Properties.apply(s, "alternate-background-color", "green")
    alt = s.alternate_row
    alt.bg.should eq rgb("green")
    alt.fg.should eq rgb("yellow")
  end
end

describe "BUGS13 S11 Length never raises on out-of-Float64-range literals" do
  huge = "9" * 400 # > ~1.8e308: strict String#to_f raises ArgumentError (ERANGE)

  it "to_cells returns nil for a bare out-of-range number" do
    Crysterm::CSS::Length.to_cells(huge).should be_nil
  end

  it "to_cells returns nil for an out-of-range unit'd length" do
    Crysterm::CSS::Length.to_cells("#{huge}px").should be_nil
    Crysterm::CSS::Length.to_cells("#{huge}em", vertical: true).should be_nil
  end

  it "to_cells_f returns nil for an out-of-range decimal" do
    Crysterm::CSS::Length.to_cells_f("#{huge}.5").should be_nil
  end

  it "viewport_cells returns nil for an out-of-range vw" do
    Crysterm::CSS::Length.viewport_cells("#{huge}vw", 80, 24).should be_nil
  end

  it "calc() containing an out-of-range term resolves to nil" do
    Crysterm::CSS::Length.to_cells("calc(#{huge} + 1)").should be_nil
  end

  it "a Properties longhand drops the declaration instead of raising" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding-left", "2")
    Crysterm::CSS::Properties.apply(s, "padding-left", huge)
    s.padding.left.should eq 2
  end

  it "still resolves ordinary lengths (no regression)" do
    Crysterm::CSS::Length.to_cells("5").should eq 5
    Crysterm::CSS::Length.to_cells("200px").should eq 20
    Crysterm::CSS::Length.to_cells("calc(200px + 2em)").should eq 22
    Crysterm::CSS::Length.viewport_cells("50vw", 80, 24).should eq 40
  end
end

describe "BUGS13 S12 opacity rejects non-finite numbers" do
  it "drops nan (would crash Colors.mix on the first blended cell)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "opacity", "nan")
    s.opacity.should be_nil
  end

  it "drops inf / -infinity / nan%" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "opacity", "inf")
    s.opacity.should be_nil
    Crysterm::CSS::Properties.apply(s, "opacity", "-infinity")
    s.opacity.should be_nil
    Crysterm::CSS::Properties.apply(s, "opacity", "nan%")
    s.opacity.should be_nil
  end

  it "does not clobber a previously-set alpha with NaN" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "opacity", "0.4")
    Crysterm::CSS::Properties.apply(s, "opacity", "nan")
    s.opacity.should eq 0.4
  end

  it "still parses ordinary numbers and percentages, clamped (no regression)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "opacity", "0.5")
    s.opacity.should eq 0.5
    Crysterm::CSS::Properties.apply(s, "opacity", "50%")
    s.opacity.should eq 0.5
    Crysterm::CSS::Properties.apply(s, "opacity", "2.5")
    s.opacity.should eq 1.0
  end
end

describe "BUGS13 S13 parse_time rejects overflow durations" do
  it "does not raise OverflowError on a huge transition duration" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "transition", "opacity 9e30s")
    # The bogus time token is dropped; the entry falls back to the default.
    s.transitions.not_nil!["opacity"][0].should eq 0.3.seconds
  end

  it "does not raise on nan/inf duration spellings" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "transition", "opacity NaNs")
    s.transitions.not_nil!["opacity"][0].should eq 0.3.seconds
    Crysterm::CSS::Properties.apply(s, "transition", "opacity infs")
    s.transitions.not_nil!["opacity"][0].should eq 0.3.seconds
  end

  it "does not raise on a huge animation duration" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "animation", "spin 9e30s")
    s.animation.not_nil!.duration.should eq 1.seconds # the default
  end

  it "still parses ordinary durations (no regression)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "transition", "opacity 250ms")
    s.transitions.not_nil!["opacity"][0].should eq 250.milliseconds
    Crysterm::CSS::Properties.apply(s, "transition", "opacity 2s")
    s.transitions.not_nil!["opacity"][0].should eq 2.seconds
  end
end

describe "BUGS13 S14 negative transition duration invalidates the entry" do
  it "drops a negative-duration property entirely" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "transition", "opacity -5s")
    s.transitions.should be_nil
  end

  it "keeps other comma-separated entries" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "transition", "opacity -5s, color 1s")
    t = s.transitions.not_nil!
    t.has_key?("opacity").should be_false
    t["color"][0].should eq 1.seconds
  end

  it "keeps a zero duration (instant-complete, not immortal)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "transition", "opacity 0s")
    s.transitions.not_nil!["opacity"][0].should eq 0.seconds
  end
end

describe "BUGS13 S15 comment stripping honors quoted strings" do
  it "keeps /*...*/ inside a quoted url() path" do
    sheet = Crysterm::CSS::Stylesheet.parse(%q(Box { background-image: url("/a/*x*/b.png"); }))
    sheet.rules.first.declarations["background-image"].should eq %q(url("/a/*x*/b.png"))
  end

  it "keeps /* inside an attribute-selector string" do
    sheet = Crysterm::CSS::Stylesheet.parse(%q(Box[name="a/*b*/c"] { color: red; }))
    sheet.rules.first.selector.should contain %q(a/*b*/c)
    sheet.rules.first.declarations["color"].should eq "red"
  end

  it "keeps /* inside a glyphs string" do
    sheet = Crysterm::CSS::Stylesheet.parse(%q(Box { glyphs: "/*"; }))
    sheet.rules.first.declarations["glyphs"].should eq %q("/*")
  end

  it "still strips real comments, including multi-line and unterminated" do
    sheet = Crysterm::CSS::Stylesheet.parse("/* a\nb */ Box { color: /* mid */ red; } /* trailing")
    sheet.rules.size.should eq 1
    sheet.rules.first.declarations["color"].should eq "red"
  end

  it "strips a comment between a quote-bearing declaration and the next rule" do
    css = %q(Box { glyphs: "x"; } /* between */ Label { color: blue; })
    sheet = Crysterm::CSS::Stylesheet.parse(css)
    sheet.rules.size.should eq 2
  end
end
