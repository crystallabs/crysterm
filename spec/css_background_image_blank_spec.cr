require "./spec_helper"

include Crysterm

# CSS `background-image` longhand (`Crysterm::CSS::Properties.apply`): an
# undefined `var(--x)` collapses to "" before reaching the property, and per
# CSS's "drop the invalid declaration" rule it must be ignored, not clear a
# previously-cascaded image. The old unguarded form ran
# `parse_background_image("")` -> `nil`, clobbering it. The `background`
# shorthand already guards this; the longhand must too.
describe "CSS background-image blank longhand" do
  it "drops a blank value, keeping a previously-set image" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-image", "url(x.png)")
    # A collapsed undefined `var()` reaches here as "" and must not clear the image.
    Crysterm::CSS::Properties.apply(s, "background-image", "")
    s.background_image.should eq "x.png"
  end

  it "still clears the image on an explicit `none`" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-image", "url(x.png)")
    Crysterm::CSS::Properties.apply(s, "background-image", "none")
    s.background_image.should be_nil
  end
end
