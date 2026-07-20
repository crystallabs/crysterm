require "./spec_helper"

include Crysterm

private def mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 30,
    height: 15,
    default_quit_keys: false)
end

# Regression: a shrink-to-content (`shrink_to_fit`) list computes its height from the
# item count. `minimal_children_rectangle`'s top-anchored placement adds only
# the *bottom* inset (`yl += ibottom`), so the item count must fold in the *top*
# inset too. It didn't — a bordered shrink list came out one row too short
# (`items + ibottom` instead of `items + ivertical`), clipping its last item.
describe "Widget::List shrink-to-content height with a border" do
  it "sizes to fit all items plus both insets, showing the last item" do
    s = mem_screen
    l = Crysterm::Widget::List.new parent: s, top: 0, left: 0, shrink_to_fit: true,
      style: Crysterm::Style.new(border: true)
    l.items = ["one", "two", "three"]
    s.repaint

    lp = l.lpos.not_nil!
    height = lp.yl - lp.yi

    l.ivertical.should eq 2 # top + bottom border
    # Full box: one row per item plus the top and bottom insets.
    height.should eq 3 + l.ivertical

    # The last item must actually be painted (not clipped below the box).
    buffer = String.build do |io|
      (lp.yi...lp.yl).each do |y|
        (lp.xi...lp.xl).each { |x| io << s.lines[y][x].char }
      end
    end
    buffer.includes?("three").should be_true
  end
end
