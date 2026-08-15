require "./spec_helper"

include Crysterm

# API.md §2.3 (Top-20 #17) — the `AbstractButton#text`/`#content`
# never-disagree guarantee holds on the marker controls too: both accessors
# are the bare label, and the composed `[x] label` line the paint writes is
# render-internal (visible only via `#rendered_content`).

describe "marker controls' text/content guarantee (§2.3)" do
  it "CheckBox: #content is the label, before and after painting" do
    s = headless_screen(80, 24)
    cb = Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1,
      content: "Accept"

    cb.text.should eq "Accept"
    cb.content.should eq "Accept"

    s.repaint # paint composes the marker line internally
    cb.content.should eq "Accept"
    cb.text.should eq cb.content
    cb.rendered_content.should contain "Accept" # the drawn line has the label...
    cb.rendered_content.should_not eq "Accept"  # ...plus the marker cells
  end

  it "writing either spelling sets the label, and toggling never touches it" do
    s = headless_screen(80, 24)
    cb = Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1,
      content: "Accept"
    s.repaint

    cb.content = "Agree"
    cb.text.should eq "Agree"
    cb.content.should eq "Agree"

    cb.text = "Consent"
    cb.content.should eq "Consent"

    cb.toggle
    s.repaint
    cb.content.should eq "Consent" # the marker flip is render-only
  end

  it "RadioButton: same guarantee" do
    s = headless_screen(80, 24)
    rb = Widget::RadioButton.new parent: s, top: 0, left: 0, width: 20, height: 1,
      content: "Blue"
    s.repaint

    rb.content.should eq "Blue"
    rb.text.should eq rb.content
    rb.content = "Red"
    rb.text.should eq "Red"
  end
end
