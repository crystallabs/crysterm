require "./spec_helper"

include Crysterm

# A fixed-width `ListTable` whose columns fit but that overflows *vertically*
# (so a vertical scroll bar shows) must NOT report a horizontal overflow. The
# vertical bar reserves one column via `content_margin_x`, and `content_width`
# subtracts it, so comparing `row_width` (which fills the full interior) against
# `content_width` reported a phantom 1-column horizontal overflow — drawing a
# spurious horizontal scroll bar across the bottom viewport row.
describe Crysterm::Widget::ListTable do
  it "does not report horizontal overflow when only the vertical bar is present" do
    s = headless_screen(80, 24)
    rows = [["Name"]] of Array(String)
    (1..20).each { |i| rows << ["Row#{i}"] }
    lt = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, width: 20, height: 6, rows: rows
    s.repaint

    # Columns fit the interior; only vertical scrolling is needed.
    lt.overflows_x?.should be_false

    # And the bottom viewport row shows data, not a solid horizontal-bar block.
    yi = lt.atop
    bottom = String.build do |io|
      (lt.aleft...(lt.aleft + lt.awidth)).each { |x| io << (s.lines[yi + lt.aheight - 1][x]?.try(&.char) || ' ') }
    end
    bottom.should contain("Row")
    bottom.should_not contain("███")
  end

  it "still reports horizontal overflow when columns genuinely exceed the interior" do
    s = headless_screen(80, 24)
    wide = [["AAAAA", "BBBBB", "CCCCC", "DDDDD"], ["1", "2", "3", "4"], ["5", "6", "7", "8"]]
    lt = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, width: 14, height: 5, rows: wide
    s.repaint

    lt.overflows_x?.should be_true
  end
end
