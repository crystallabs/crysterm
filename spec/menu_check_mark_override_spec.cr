require "./spec_helper"

include Crysterm

# The menu's check column is measured on the marks the rows draw, as the rows
# pad them: a mark overridden with a multi-codepoint glyph (`Glyphs.set`) on a
# window without full Unicode counts the same width in both, where the column
# was measured by grapheme width and the padding by codepoint count, so the
# padding came out negative and building the rows raised.

describe "Menu check column with an overridden mark" do
  it "fits a multi-codepoint mark without full Unicode" do
    Glyphs.set Glyphs::Role::CheckMarkChecked, unicode: "🏳️‍🌈"
    begin
      s = headless_screen(40, 10)
      s.full_unicode = false
      menu = Widget::Menu.new parent: s, top: 0, left: 0, width: 24, height: 4
      menu << Action.new("Wrap", checkable: true, checked: true) << Action.new("Ruler", checkable: true)
      s.repaint
      rows = menu.item_boxes.map &.content.rstrip
      rows[0].should eq "🏳️‍🌈 Wrap"
      # The label column is shared: "Ruler" starts where "Wrap" does.
      rows[1].should eq "☐    Ruler"
    ensure
      Glyphs.reset
    end
  end
end
