require "./spec_helper"

include Crysterm

# Regression: `minimal_children_rectangle`'s list branch anchored the extent
# at absolute row 0 (`myi = 0; myl = items + itop`) while `myi`/`myl` are
# absolute window coordinates seeded from the widget's own top (`yi`). That is
# only correct at `yi == 0`; for any other position the children rectangle came
# out inverted/truncated, `minimal_rectangle_uncached`'s span comparison
# discarded it, and the box collapsed — clipping the list's items.
describe "Widget::List shrink-to-content height at a non-zero top offset" do
  it "sizes to fit all items plus both insets when top is non-zero" do
    s = headless_screen(30, 15)
    l = Crysterm::Widget::List.new parent: s, top: 5, left: 0, shrink_to_fit: true,
      style: Crysterm::Style.new(border: true)
    l.items = ["one", "two", "three"]
    s.repaint

    lp = l.lpos.not_nil!
    lp.yi.should eq 5
    # Full box: one row per item plus the top and bottom insets.
    (lp.yl - lp.yi).should eq 3 + l.ivertical

    # The last item must actually be painted (not clipped below the box).
    buffer = String.build do |io|
      (lp.yi...lp.yl).each do |y|
        (lp.xi...lp.xl).each { |x| io << s.lines[y][x].char }
      end
    end
    buffer.includes?("three").should be_true
  end

  it "sizes correctly when nested inside a positioned parent" do
    s = headless_screen(30, 15)
    box = Crysterm::Widget::Box.new parent: s, top: 2, left: 1, width: 25, height: 12
    l = Crysterm::Widget::List.new parent: box, top: 3, left: 0, shrink_to_fit: true,
      style: Crysterm::Style.new(border: true)
    l.items = ["one", "two", "three"]
    s.repaint

    lp = l.lpos.not_nil!
    # Absolute top: parent top (2) + own top (3).
    lp.yi.should eq 5
    (lp.yl - lp.yi).should eq 3 + l.ivertical

    buffer = String.build do |io|
      (lp.yi...lp.yl).each do |y|
        (lp.xi...lp.xl).each { |x| io << s.lines[y][x].char }
      end
    end
    buffer.includes?("three").should be_true
  end
end
