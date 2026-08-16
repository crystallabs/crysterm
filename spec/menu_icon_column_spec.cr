require "./spec_helper"

include Crysterm

# The menu's icon slot is a measured shared column (like the check column):
# the widest visible icon plus a gap, applied to every row — so icon-less
# entries and narrower icons indent to the same label column instead of
# sitting flush left. With no visible icon anywhere, the column vanishes.

describe "Menu icon column" do
  it "indents icon-less rows and pads narrower icons to the shared column" do
    s = headless_screen(80, 24)
    menu = Widget::Menu.new parent: s, top: 0, left: 0
    menu.add_action "Alpha", icon: "*"
    menu.add_action "Beta", icon: "<>"
    menu.add_action "Gamma"
    s.repaint

    # Widest icon "<>" is 2 columns + 1 gap = a 3-column slot for every row.
    menu.@row_lefts.should eq ["*  Alpha", "<> Beta", "   Gamma"]
  end

  it "adds no column when no visible entry has an icon" do
    s = headless_screen(80, 24)
    menu = Widget::Menu.new parent: s, top: 0, left: 0
    menu.add_action "Alpha"
    menu.add_action "Beta"
    s.repaint

    menu.@row_lefts.should eq ["Alpha", "Beta"]
  end

  it "drops the column once the last icon-bearing entry is hidden" do
    s = headless_screen(80, 24)
    menu = Widget::Menu.new parent: s, top: 0, left: 0
    iconful = menu.add_action "Alpha", icon: "*"
    menu.add_action "Beta"
    s.repaint
    menu.@row_lefts.should eq ["* Alpha", "  Beta"]

    iconful.visible = false
    menu.@row_lefts.should eq ["Beta"]
  end

  it "keeps the icon column after the shared check column" do
    s = headless_screen(80, 24)
    menu = Widget::Menu.new parent: s, top: 0, left: 0
    menu << Action.new("Wrap", checkable: true, icon: "*")
    menu.add_action "Reload"
    s.repaint

    lefts = menu.@row_lefts
    lefts.size.should eq 2
    # Both rows share the check column and the icon column, so the labels
    # start at the same display column (glyph set left tier-agnostic here).
    lefts[0].should end_with "Wrap"
    lefts[1].should end_with "Reload"
    pre0 = lefts[0][0, lefts[0].size - "Wrap".size]
    pre1 = lefts[1][0, lefts[1].size - "Reload".size]
    Crysterm::Unicode.str_width(pre0, true).should eq Crysterm::Unicode.str_width(pre1, true)
    pre1.strip.empty?.should be_true # icon-less, non-checkable: pure indent
  end
end
