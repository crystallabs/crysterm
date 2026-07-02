require "./spec_helper"

include Crysterm

# Regression spec for the BUGS7 media-overlay fix: the external-helper backends
# (`Media::Overlay`, `Media::Ueberzug`) and the in-band `Media::Graphics` all run
# their repaint as a standalone `Event::Rendered` listener, so they must skip
# when THIS widget *or any ancestor* is hidden — resolving rendered coordinates
# against a hidden ancestor (which has no rendered position) would raise and kill
# the render fiber. The shared `Widget#visible_in_tree?` helper backs all three.

private def med_window(w = 20, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "BUGS7 Widget#visible_in_tree?" do
  it "is false for a descendant when an ancestor is hidden (own flag unchanged)" do
    s = med_window
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 6
    inner = Widget::Box.new parent: outer, top: 0, left: 0, width: 8, height: 4
    leaf = Widget::Box.new parent: inner, top: 0, left: 0, width: 4, height: 2

    leaf.visible?.should be_true
    leaf.visible_in_tree?.should be_true

    outer.hide                            # only sets outer's own flag; the leaf stays `visible?`
    leaf.visible?.should be_true          # own flag untouched
    leaf.visible_in_tree?.should be_false # but an ancestor is hidden

    outer.show
    leaf.visible_in_tree?.should be_true
  end

  it "is false for a media widget under a hidden container (the crash guard)" do
    s = med_window
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 4
    img = Widget::Media::Kitty.new parent: box, width: 4, height: 2

    img.visible_in_tree?.should be_true
    box.hide
    img.visible?.should be_true          # descendant's own flag stays true
    img.visible_in_tree?.should be_false # so redraw_image bails instead of raising
  end

  it "renders a window with a hidden container holding a graphic without raising" do
    s = med_window
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 4
    Widget::Media::Kitty.new parent: box, width: 4, height: 2
    box.hide
    # The `Rendered` listener runs on render; with the guard it must no-op rather
    # than resolve coords against the hidden `box`.
    s._render
  end
end
