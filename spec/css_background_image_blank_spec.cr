require "./spec_helper"

include Crysterm

# Focused spec for the CSS `background-image` *longhand* parser
# (`Crysterm::CSS::Properties.apply`). An undefined `var(--x)` collapses to ""
# before reaching the property, and per CSS's "drop the invalid declaration"
# rule it must be ignored — leaving any previously-cascaded image intact. The
# old unguarded form ran `parse_background_image("")` -> `nil`, silently
# *clearing* a `background-image` a lower-priority rule had set. The
# `background` shorthand already guards this exact case; the longhand must too.
describe "CSS background-image blank longhand" do
  it "drops a blank value, keeping a previously-set image" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-image", "url(x.png)")
    # A collapsed undefined `var()` reaches here as "". It must NOT clear the
    # image — that would be the longhand silently dropping a lower-priority rule.
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
