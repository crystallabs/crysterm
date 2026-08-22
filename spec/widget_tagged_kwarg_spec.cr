require "./spec_helper"

include Crysterm

# The `tagged:` construction shorthand: `content:` + `parse_tags: true` in one
# argument, winning over `content:` when both are given.

describe "Widget#initialize tagged:" do
  it "sets the content and enables tag parsing" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
      tagged: "{bold}hi{/bold}"
    s.repaint
    b.parse_tags?.should be_true
    b.content.should eq "{bold}hi{/bold}"
    b.rendered_text.should eq "hi"
  end

  it "wins over content: when both are given" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
      content: "plain", tagged: "{bold}tagged{/bold}"
    s.repaint
    b.rendered_text.should eq "tagged"
  end

  it "flows through subclass splat initializers (Label)" do
    s = headless_screen(80, 24)
    l = Widget::Label.new parent: s, top: 0, left: 0, width: 20, height: 3,
      tagged: "{bold}hi{/bold}"
    s.repaint
    l.rendered_text.should eq "hi"
  end
end
